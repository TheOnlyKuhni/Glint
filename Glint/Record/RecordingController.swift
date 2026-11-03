import AppKit
import AVFoundation
import SwiftUI

/// What the recorder makes: a video, a GIF, or a Studio Mode project (video without the cursor, plus the pointer,
/// keys and camera kept separately for the video editor).
enum RecordMode { case video, gif, studio }

/// "Record Screen": pick an area (or a window), choose the options in the panel and start a GIF (⌥↩)
/// or video (↩) recording. While recording the rest of the screen can be dimmed, a control bar under the area
/// stops, pauses, restarts or deletes, and the menu bar shows the time. The result goes through the recording
/// after-capture actions (Quick Access by default).
final class RecordingController {
    static let shared = RecordingController()

    private(set) var isRecording = false
    private var selector: RegionSelector?
    private var session: RecordingSession?
    /// The area before the panel's full-screen button was pressed; pressing it again goes back.
    private var areaBeforeFullScreen: CGRect?

    /// Shortcut / menu: starts the selection, or stops a running recording. `initial` (from All-In-One) starts with
    /// that area instead of the remembered one.
    /// `studio` ("Start Studio Mode Recording"): Return starts a Studio Mode recording.
    func toggle(initial: CGRect? = nil, studio: Bool = false) {
        if let session { session.stop(); return }
        guard selector == nil, Permissions.ensureScreenRecording() else { return }
        let selector = RegionSelector(hint: "Drag to record a part of the screen. Press Space to select a window.")
        let model = RecordPanelModel()
        selector.onChange = { [unowned selector] rect in
            model.size = rect.size
            model.isFullScreen = rect == selector.screen.cgFrame
            // The camera appears once the area is released, not while it's being drawn.
            WebcamOverlay.shared.areaChanged(selector.isDrawing ? .zero : Geometry.appKitRect(fromCG: rect))
        }
        selector.onCancel = { [weak self, unowned selector] in
            // Setting up an area counts as a selection, even when the recorder is left with Esc.
            if !selector.rect.isEmpty { Defaults[Prefs.recLastArea] = selector.rect.storageString }
            self?.selector = nil
            WebcamOverlay.shared.hide()
        }
        selector.onConfirm = { [weak self] option in self?.start(option ? .gif : studio ? .studio : .video) }
        // Without "Remember last selection" every recording starts freeform with no area (the other options —
        // microphone, camera, clicks… — always keep their last state).
        let remember = Defaults[Prefs.recRememberSelection]
        if !remember { Defaults[Prefs.recRatio] = "" }
        selector.ratio = RecordRatio.value(Defaults[Prefs.recRatio])
        model.actions = RecordPanelActions(
            record: { [weak self] mode in self?.start(mode) },
            resize: { [weak selector] size in selector?.resize(to: size) },
            fullScreen: { [weak self, weak selector] in
                guard let self, let selector else { return }
                let full = selector.screen.cgFrame
                if selector.rect == full {
                    // Back to the area from before, or (drawn full screen) a centered two-thirds one.
                    let back = self.areaBeforeFullScreen ?? full.insetBy(dx: full.width / 6, dy: full.height / 6)
                    selector.set(back)
                    self.areaBeforeFullScreen = nil
                } else {
                    self.areaBeforeFullScreen = selector.rect.isEmpty ? nil : selector.rect
                    selector.set(full)
                }
            },
            ratioChanged: { [weak selector] in
                selector?.ratio = RecordRatio.value(Defaults[Prefs.recRatio])
                selector?.applyRatio()
            }
        )
        let host = NSHostingView(rootView: RecordPanel(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        selector.setAccessory(host, placement: .center)
        self.selector = selector
        areaBeforeFullScreen = nil
        WebcamOverlay.shared.attach(to: selector)
        // It starts with the hint unless "Remember last selection" is on.
        let last = initial ?? (remember ? CGRect(storageString: Defaults[Prefs.recLastArea]) : nil)
        selector.begin(initial: last)
    }

    func togglePause() { session?.togglePause() }
    func restart() { session?.restart() }

    private func start(_ mode: RecordMode) {
        guard let selector, !selector.rect.isEmpty else { return }
        // A camera without a microphone records a silent face, so it asks first.
        if mode != .gif, !Defaults[Prefs.recCamera].isEmpty, Defaults[Prefs.recMicDevice].isEmpty {
            let alert = NSAlert()
            alert.messageText = "No microphone selected"
            alert.informativeText = "You’ve enabled camera recording, but no microphone is selected. Select a mic to include sound in your video."
            alert.addButton(withTitle: "Don't Record Audio")
            alert.addButton(withTitle: "Cancel")
            guard selector.runBelowAlert(alert) == .alertFirstButtonReturn else { return }
        }
        let rect = selector.rect, screen = selector.screen
        Defaults[Prefs.recLastArea] = rect.storageString
        let session = RecordingSession(rect: rect, screen: screen, mode: mode)
        // The session's dim window is up before the selection (panel, brackets) fades away.
        session.prepare()
        WebcamOverlay.shared.beginRecording(area: Geometry.appKitRect(fromCG: rect), studio: session.studioClock, folder: session.studioFolder)
        selector.end(animated: true)
        self.selector = nil
        session.onFinish = { [weak self] in
            WebcamOverlay.shared.hide()
            self?.session = nil
            self?.isRecording = false
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        }
        self.session = session
        isRecording = true
        Task { await session.begin() }
    }
}

extension Notification.Name {
    /// Posted when a recording starts, ticks (once a second) or ends; the status item shows the time.
    static let recordingStateChanged = Notification.Name("GlintRecordingStateChanged")
}

// MARK: - A running recording

/// Countdown, the dimmed surroundings, the control bar, click highlights, keystrokes and the recorder itself.
final class RecordingSession {
    let rect: CGRect
    let screen: NSScreen
    let mode: RecordMode
    var isGIF: Bool { mode == .gif }
    var onFinish: (() -> Void)?
    /// Studio Mode: the clock events are timed with, and the folder the pointer, keys and camera go into.
    private(set) var studioClock: RecordingClock?
    private(set) var studioFolder: URL?
    private var tracker: StudioTracker?

    private var recorder: ScreenRecorder?
    private var dimWindow: NSWindow?
    private var controls: NSPanel?
    private let state = RecordingState()
    private var timer: Timer?
    private var started: Date?
    private var pausedTime: TimeInterval = 0
    private var pauseBegan: Date?
    private var monitors: [Any] = []
    private var keystrokes: KeystrokeOverlay?
    private var finished = false

    init(rect: CGRect, screen: NSScreen, mode: RecordMode) {
        self.rect = rect
        self.screen = screen
        self.mode = mode
        if mode == .studio {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GlintStudio-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            studioFolder = folder
            studioClock = RecordingClock()
        }
    }

    private var appKitRect: CGRect { Geometry.appKitRect(fromCG: rect) }

    func prepare() {
        showDim()
        MicLevel.shared.retain()
    }

    func begin() async {
        if dimWindow == nil { showDim() }
        if Defaults[Prefs.recCountdown] { await Countdown.run(seconds: 3, on: screen) }
        guard !finished else { return }
        await startRecorder()
        DoNotDisturb.begin()
        // The control bar fades in a moment after recording starts.
        try? await Task.sleep(for: .milliseconds(450))
        guard !finished else { return }
        showControls()
        // Studio Mode records clicks and keys as data; the editor draws them.
        guard mode != .studio else { return }
        if Defaults[Prefs.recHighlightClicks] { startClickHighlights() }
        if Defaults[Prefs.recShowKeystrokes] { keystrokes = KeystrokeOverlay(area: appKitRect) }
    }

    private func startRecorder() async {
        let options = ScreenRecorder.Options(rect: rect, screen: screen, frameRate: isGIF ? Defaults[Prefs.gifFrameRate] : Defaults[Prefs.recFrameRate],
                                             showsCursor: mode != .studio && Defaults[Prefs.recShowCursor],
                                             systemAudio: Defaults[Prefs.recSystemAudio],
                                             microphone: Defaults[Prefs.recMicDevice], isGIF: isGIF, isStudio: mode == .studio)
        let recorder = studioClock.map { ScreenRecorder(options: options, clock: $0) } ?? ScreenRecorder(options: options)
        do {
            try await recorder.start()
        } catch {
            glintLog("recording failed to start: \(error)")
            NSSound.beep()
            cleanUp()
            return
        }
        self.recorder = recorder
        if let studioClock, let studioFolder, tracker == nil {
            let tracker = StudioTracker(area: rect, folder: studioFolder, clock: studioClock)
            tracker.start()
            self.tracker = tracker
        }
        started = Date()
        pausedTime = 0
        state.elapsed = 0
        state.paused = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    private func tick() {
        guard let started else { return }
        let paused = pausedTime + (pauseBegan.map { Date().timeIntervalSince($0) } ?? 0)
        let seconds = Int(Date().timeIntervalSince(started) - paused)
        if seconds != state.elapsed {
            state.elapsed = seconds
            RecordingStatus.elapsed = seconds
            NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
        }
    }

    func togglePause() {
        guard let recorder else { return }
        state.paused.toggle()
        recorder.setPaused(state.paused)
        if state.paused { pauseBegan = Date() } else if let began = pauseBegan { pausedTime += Date().timeIntervalSince(began); pauseBegan = nil }
        RecordingStatus.paused = state.paused
        NotificationCenter.default.post(name: .recordingStateChanged, object: nil)
    }

    /// Throws the recording so far away and starts over.
    func restart() {
        recorder?.discard()
        recorder = nil
        studioClock?.reset()
        tracker?.reset()
        WebcamOverlay.shared.restartFileRecording()
        Task { await startRecorder() }
    }

    func delete() {
        recorder?.discard()
        recorder = nil
        discardStudio()
        cleanUp()
    }

    private func discardStudio() {
        guard let studioFolder else { return }
        _ = tracker?.finish()
        tracker = nil
        let camera = WebcamOverlay.shared.detachFileRecorder()
        Task {
            _ = await camera?.finish()
            try? FileManager.default.removeItem(at: studioFolder)
        }
    }

    func stop() {
        guard let recorder else { discardStudio(); cleanUp(); return }
        self.recorder = nil
        let duration = Double(state.elapsed)
        if mode == .studio { stopStudio(recorder, duration: duration); return }
        cleanUp()
        let isGIF = isGIF, rect = rect
        Task {
            guard let movie = await recorder.stop() else { NSSound.beep(); return }
            var file = movie
            if !isGIF, Defaults[Prefs.recAudioTracks] == .single, let mixed = await AudioMixdown.singleTrack(movie) {
                file = mixed
            }
            if isGIF {
                let gif = movie.deletingPathExtension().appendingPathExtension("gif")
                guard await GIFEncoder.encode(movie: movie, to: gif) else { NSSound.beep(); return }
                file = gif
            }
            CaptureOutput.deliverRecording(file, duration: duration, screenRect: rect)
            try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
        }
    }

    /// Studio Mode: the video, the pointer and keys, and the camera movie become one project in the history, which
    /// opens in the video editor.
    private func stopStudio(_ recorder: ScreenRecorder, duration: Double) {
        guard let folder = studioFolder, let tracker else { cleanUp(); return }
        var data = tracker.finish()
        self.tracker = nil
        let camera = WebcamOverlay.shared.detachFileRecorder()
        cleanUp()
        Task {
            guard let movie = await recorder.stop() else {
                _ = await camera?.finish()
                try? FileManager.default.removeItem(at: folder)
                NSSound.beep()
                return
            }
            var file = movie
            if Defaults[Prefs.recAudioTracks] == .single, let mixed = await AudioMixdown.singleTrack(movie) { file = mixed }
            if let camera, let offset = await camera.finish() {
                data.camera = camera.url.lastPathComponent
                data.cameraOffset = offset
            }
            do { try data.write(to: folder) } catch { glintLog("studio: can't save the recording data: \(error)") }
            CaptureOutput.deliverStudioRecording(file, studio: folder, duration: duration)
            try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
        }
    }

    private func cleanUp() {
        guard !finished else { return }
        finished = true
        DoNotDisturb.end()
        MicLevel.shared.release()
        timer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        keystrokes?.close()
        dimWindow?.orderOut(nil)
        controls?.orderOut(nil)
        RecordingStatus.elapsed = 0
        RecordingStatus.paused = false
        onFinish?()
    }

    // MARK: Windows

    private func showDim() {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let view = DimView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.hole = appKitRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        view.dims = Defaults[Prefs.recDimScreen]
        window.contentView = view
        window.orderFrontRegardless()
        dimWindow = window
    }

    private func showControls() {
        guard Defaults[Prefs.recShowControls] else { return }
        let view = ControlBar(state: state, actions: ControlBarActions(
            stop: { [weak self] in self?.stop() },
            pause: { [weak self] in self?.togglePause() },
            restart: { [weak self] in self?.restart() },
            delete: { [weak self] in self?.delete() }
        ))
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let area = appKitRect, visible = screen.visibleFrame
        // Under the area, above it when there's no room below, else inside its bottom edge (full screen).
        var origin = CGPoint(x: area.midX - size.width / 2, y: area.minY - 10 - size.height)
        if origin.y < visible.minY { origin.y = area.maxY + 10 }
        if origin.y + size.height > visible.maxY { origin.y = area.minY + 20 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        controls = panel
    }

    private func startClickHighlights() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            guard self.appKitRect.contains(p) else { return }
            ClickHighlight.show(at: p)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { handler($0); return $0 }) { monitors.append(m) }
    }
}

/// Shared with the status item.
enum RecordingStatus {
    static var elapsed = 0
    static var paused = false
    static var timeString: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }
}

final class RecordingState: ObservableObject {
    @Published var elapsed = 0
    @Published var paused = false
}

struct ControlBarActions {
    var stop: () -> Void
    var pause: () -> Void
    var restart: () -> Void
    var delete: () -> Void
}

/// The recording controls, measured: a 232×46pt bar (#272828, 1pt #323333 border) with stop + time (75pt),
/// pause, restart and delete (42pt each) and a darker 24pt grip, split by 1pt lines.
private struct ControlBar: View {
    @ObservedObject var state: RecordingState
    @ObservedObject private var mic = MicLevel.shared
    private let recordsMic = !Defaults[Prefs.recMicDevice].isEmpty
    let actions: ControlBarActions
    private static let red = Color(red: 0xEC / 255.0, green: 0x5F / 255.0, blue: 0x59 / 255.0)
    private static let fill = Color(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x28 / 255.0)
    private static let line = Color(red: 0x32 / 255.0, green: 0x33 / 255.0, blue: 0x33 / 255.0)
    private static let grip = Color(red: 0x1F / 255.0, green: 0x20 / 255.0, blue: 0x20 / 255.0)

    var body: some View {
        HStack(spacing: 0) {
            Button(action: actions.stop) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().strokeBorder(Self.red, lineWidth: 1.6).frame(width: 18, height: 18)
                        RoundedRectangle(cornerRadius: 1.5).fill(Self.red).frame(width: 7, height: 7)
                    }
                    Text(String(format: "%d:%02d", state.elapsed / 60, state.elapsed % 60))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Self.red)
                }
                .frame(width: 75, height: 46)
                // The microphone level, like the panel's mic cell.
                .background(alignment: .bottom) { if recordsMic { LevelBand(level: mic.level) } }
                .contentShape(Rectangle())
            }
            .buttonStyle(BarPressStyle()).help("Stop recording")
            divider
            barButton(state.paused ? "play.circle" : "pause.circle", help: state.paused ? "Resume" : "Pause", action: actions.pause)
            divider
            barButton("arrow.counterclockwise", help: "Restart", action: actions.restart)
            divider
            barButton("trash", help: "Delete", action: actions.delete)
            divider
            VStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color.white.opacity(0.3)).frame(width: 6, height: 1) } }
                .frame(width: 24, height: 46)
                .background(Self.grip)
                .help("Drag to move")
        }
        .background(Self.fill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Self.line, lineWidth: 1))
        .fixedSize()
    }

    private var divider: some View { Rectangle().fill(Self.line).frame(width: 1, height: 46) }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.white)
                .frame(width: 42, height: 46).contentShape(Rectangle())
        }
        .buttonStyle(BarPressStyle()).help(help)
    }
}

private struct BarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.6 : 1) }
}

/// Darkens everything but the recorded area ("Dim screen while recording", on by default): it keeps the
/// area visible like this while recording, at 50% black.
private final class DimView: NSView {
    var hole: CGRect = .zero
    var dims = false
    override func draw(_ dirtyRect: NSRect) {
        guard dims, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.addRect(bounds)
        ctx.addRect(hole)
        ctx.fillPath(using: .evenOdd)
    }
}

/// The click marker (filmed at 60 fps): a blue ring without fill that fades in over 0.1 s while it grows
/// from 17 to 35pt radius (ease-out) and thins from 3 to ~1pt, then fades out; ~0.35 s in all (recorded).
enum ClickHighlight {
    static let duration: TimeInterval = 0.35

    static func show(at p: NSPoint) {
        let size: CGFloat = 80
        let window = NSWindow(contentRect: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = RecordingOverlayTitle.recorded
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ClickRing(start: Date()))
        host.frame = CGRect(x: 0, y: 0, width: size, height: size)
        window.contentView = host
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { window.orderOut(nil) }
    }

    private struct ClickRing: View {
        let start: Date
        var body: some View {
            TimelineView(.animation) { context in
                Canvas { ctx, size in
                    let t = context.date.timeIntervalSince(start)
                    let p = min(max(t / 0.33, 0), 1)
                    let grow = 1 - (1 - p) * (1 - p)
                    let width = 3 - 1.9 * p
                    let radius = 17 + 18 * grow - width / 2
                    let fadeIn = min(1, t / 0.1), fadeOut = t > 0.27 ? max(0, 1 - (t - 0.27) / 0.08) : 1
                    let k = CGFloat(Defaults[Prefs.recClickSize])
                    let r = radius * k
                    let ring = Path(ellipseIn: CGRect(x: size.width / 2 - r, y: size.height / 2 - r, width: r * 2, height: r * 2))
                    let color = Color(nsColor: NSColor(hex: Defaults[Prefs.recClickColor]) ?? .systemBlue)
                    if Defaults[Prefs.recClickFilled] {
                        ctx.fill(ring, with: .color(color.opacity(0.35 * fadeIn * fadeOut)))
                    } else {
                        ctx.stroke(ring, with: .color(color.opacity(0.55 * fadeIn * fadeOut)), lineWidth: width * k)
                    }
                }
            }
        }
    }
}

/// Shows the pressed shortcut (e.g. "⇧ ⌘ 4") near the bottom of the recorded area. Needs Accessibility access.
final class KeystrokeOverlay {
    private var monitor: Any?
    private let window: NSWindow
    private let model = KeystrokeModel()
    private var hideWork: DispatchWorkItem?

    init(area: CGRect) {
        let size = CGSize(width: min(area.width, 520), height: 80)
        let top = Defaults[Prefs.recKeysPosition] == "top"
        window = NSWindow(contentRect: CGRect(x: area.midX - size.width / 2, y: top ? area.maxY - 24 - size.height : area.minY + 24,
                                              width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = RecordingOverlayTitle.recorded
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: KeystrokeView(model: model))
        window.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] in self?.show($0) }
    }

    private func show(_ event: NSEvent) {
        var parts: [String] = []
        let f = event.modifierFlags
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        let key: String = switch Int(event.keyCode) {
        case 36: "↩"
        case 48: "⇥"
        case 49: "Space"
        case 51: "⌫"
        case 53: "esc"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: (event.charactersIgnoringModifiers ?? "").uppercased()
        }
        // "Only shortcuts": plain typing (no ⌘ ⌥ ⌃) isn't shown.
        if Defaults[Prefs.recKeysShortcutsOnly], !f.contains(.command), !f.contains(.option), !f.contains(.control) { return }
        parts.append(key)
        model.text = parts.joined(separator: " ")
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.text = "" }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Defaults[Prefs.recKeysDuration], execute: work)
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        window.orderOut(nil)
    }
}

final class KeystrokeModel: ObservableObject { @Published var text = "" }

private struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeModel
    var body: some View {
        ZStack {
            if !model.text.isEmpty {
                Text(model.text)
                    .font(.system(size: [20, 26, 34][min(max(Defaults[Prefs.recKeysSize], 0), 2)], weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.75)))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: model.text)
    }
}
