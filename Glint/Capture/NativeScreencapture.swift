import AppKit
import SwiftUI

/// Area selection through macOS's own `screencapture -i` (no longer used for selection; Glint has its own overlay).
/// Gives the exact native crosshair, Space-for-window toggle and Escape handling.
enum NativeScreencapture {
    struct Result {
        let image: CGImage
        let scale: CGFloat
        /// The dragged area in global CG coordinates, nil when a window was picked instead.
        let rect: CGRect?
    }

    /// `timer`: Self-Timer seconds (`-T`): macOS shows its crosshair, then its
    /// red countdown pill at the top and its sounds. `showCursor` includes the pointer (`-C`).
    static func selectArea(timer: Int? = nil, showCursor: Bool = false) async -> Result? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = DragTracker()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-r", "-x"] + (timer.map { ["-T\($0)"] } ?? []) + (showCursor ? ["-C"] : []) + [url.path]
        do { try process.run() } catch {
            glintLog("screencapture failed to start: \(error)")
            return nil
        }
        if let timer {
            // macOS shows no countdown for -T; Glint draws its own red pill once the area is released.
            tracker.onRelease = { TimerPill.show(seconds: timer, until: process) }
        }
        tracker.start()
        glintLog("screencapture started")
        await Task.detached { process.waitUntilExit() }.value
        tracker.stop()
        glintLog("screencapture exited \(process.terminationStatus)")

        // Read into memory first: the temp file is deleted on return and CGImage decodes lazily.
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            glintLog("screencapture produced no image (status \(process.terminationStatus), file exists: \(FileManager.default.fileExists(atPath: url.path)))")
            return nil  // cancelled
        }
        let rect = tracker.rect.flatMap { $0.width >= 4 && $0.height >= 4 ? $0 : nil }
        let screen = rect.flatMap { NSScreen.containing(cgRect: $0) } ?? NSScreen.withMouse
        return Result(image: image, scale: screen?.backingScaleFactor ?? 2, rect: rect)
    }
}

extension NativeScreencapture {
    /// A fixed area (`-R`, global points) after a `timer`-second countdown with the red Timer pill. Esc cancels.
    static func capture(rect: CGRect, timer: Int, showCursor: Bool) async -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let r = rect.integral
        process.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", "-T\(timer)"]
            + (showCursor ? ["-C"] : []) + [url.path]
        do { try process.run() } catch {
            glintLog("screencapture failed to start: \(error)")
            return nil
        }
        TimerPill.show(seconds: timer, until: process)
        await Task.detached { process.waitUntilExit() }.value
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Polls the mouse while screencapture runs to remember the dragged area for "Capture Previous Area".
/// (Polling works without Accessibility permission and sees events delivered to screencapture.)
private final class DragTracker {
    private var timer: Timer?
    private var down: CGPoint?
    private var up: CGPoint?
    private var wasPressed = false
    /// The first mouse-up (the area or window was picked).
    var onRelease: (() -> Void)?

    var rect: CGRect? {
        guard let down, let up else { return nil }
        return CGRect(corner: down, up)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        let p = Geometry.cgPoint(fromAppKit: NSEvent.mouseLocation)
        if pressed, !wasPressed { down = p; up = nil }
        if pressed { up = p }
        if !pressed, wasPressed { onRelease?(); onRelease = nil }
        wasPressed = pressed
    }

    func stop() {
        poll()
        timer?.invalidate()
        timer = nil
    }
}

/// The Timer countdown: a 112×60pt red (#EC5D4D) pill with a darker outline, a translucent timer
/// icon and the white seconds, centered horizontally 58pt below the top of the screen; it counts down once a
/// second and goes away when the capture is taken.
enum TimerPill {
    private static var panel: NSPanel?

    static func show(seconds: Int, until process: Process) {
        panel?.orderOut(nil)
        guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let size = CGSize(width: 112, height: 60)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 58 - size.height, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let model = TimerPillModel(seconds: seconds)
        panel.contentView = NSHostingView(rootView: TimerPillView(model: model))
        panel.orderFrontRegardless()
        self.panel = panel
        // Esc cancels the capture while it counts down.
        ShortcutManager.shared.setEscapeHandler { if process.isRunning { process.terminate() } }
        let tick = { if Defaults[Prefs.playSounds] { NSSound(named: "Tink")?.play() } }
        tick()
        Task { @MainActor in
            for n in stride(from: seconds - 1, to: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard process.isRunning else { break }
                model.seconds = n
                tick()
            }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            ShortcutManager.shared.setEscapeHandler(nil)
            panel.orderOut(nil)
            if Self.panel === panel { Self.panel = nil }
        }
    }
}

final class TimerPillModel: ObservableObject {
    @Published var seconds: Int
    init(seconds: Int) { self.seconds = seconds }
}

private struct TimerPillView: View {
    @ObservedObject var model: TimerPillModel
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer").font(.system(size: 24, weight: .medium)).foregroundStyle(Color.white.opacity(0.45))
            Text("\(model.seconds)").font(.system(size: 34, weight: .regular).monospacedDigit()).foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.easeOut(duration: 0.2), value: model.seconds)
        }
        .frame(width: 112, height: 60)
        .background(Capsule().fill(Color(.displayP3, red: 0xEC / 255.0, green: 0x5D / 255.0, blue: 0x4D / 255.0)))
        .overlay(Capsule().strokeBorder(Color(.displayP3, red: 0xC4 / 255.0, green: 0x40 / 255.0, blue: 0x33 / 255.0), lineWidth: 1))
    }
}
