import AppKit
import AVFoundation
import SwiftUI

/// Aspect ratios of the recording ratio menu (landscape, then portrait).
enum RecordRatio {
    static let landscape: [(title: String, key: String, value: CGFloat)] = [
        ("1 : 1 (Square)", "1:1", 1), ("5 : 4 (10 : 8)", "5:4", 5 / 4), ("4 : 3", "4:3", 4 / 3), ("7 : 5", "7:5", 7 / 5),
        ("3 : 2 (6 : 4)", "3:2", 3 / 2), ("16 : 10", "16:10", 16 / 10), ("16 : 9", "16:9", 16 / 9),
        ("1.85 : 1", "1.85:1", 1.85), ("2.35 : 1", "2.35:1", 2.35),
    ]
    static let portrait: [(title: String, key: String, value: CGFloat)] = [
        ("4 : 5", "4:5", 4 / 5), ("3 : 4", "3:4", 3 / 4), ("2 : 3", "2:3", 2 / 3), ("9 : 16", "9:16", 9 / 16),
    ]

    static func value(_ key: String) -> CGFloat? { (landscape + portrait).first { $0.key == key }?.value }
}

final class RecordPanelModel: ObservableObject {
    @Published var size: CGSize = .zero
    /// The area covers the whole screen (the full-screen button then shows arrows pointing in).
    @Published var isFullScreen = false
    var actions: RecordPanelActions?
    /// Views the menus and the settings popover open from.
    var anchors: [RecordPanel.Cell: NSView] = [:]
}

struct RecordPanelActions {
    var record: (RecordMode) -> Void
    var resize: (CGSize) -> Void
    var fullScreen: () -> Void
    var ratioChanged: () -> Void
}

/// The recording panel, measured: 253pt wide; a block of two 40pt rows (settings · W × H · full screen ·
/// ratio, then microphone · system audio · camera · clicks · keystrokes), Record GIF / Record Video, and the Studio
/// Mode capsule with its travelling glow, 12pt apart. Active cells are darker with a checkmark under the icon.
struct RecordPanel: View {
    enum Cell { case settings, ratio, mic, camera }

    @ObservedObject var model: RecordPanelModel
    @AppStorage(Prefs.recMicDevice) private var micDevice
    @AppStorage(Prefs.recSystemAudio) private var systemAudio
    @AppStorage(Prefs.recCamera) private var camera
    @AppStorage(Prefs.recHighlightClicks) private var clicks
    @AppStorage(Prefs.recShowKeystrokes) private var keystrokes
    @AppStorage(Prefs.recRatio) private var ratio
    @ObservedObject private var mic = MicLevel.shared

    static let fill = Color(red: 0x28 / 255.0, green: 0x28 / 255.0, blue: 0x29 / 255.0)
    static let activeFill = Color(red: 0x20 / 255.0, green: 0x20 / 255.0, blue: 0x21 / 255.0)
    static let line = Color(red: 0x33 / 255.0, green: 0x33 / 255.0, blue: 0x34 / 255.0)
    static let gray = Color(red: 0x94 / 255.0, green: 0x94 / 255.0, blue: 0x95 / 255.0)
    private static let corner: CGFloat = 18

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    cell(.settings, active: false, help: "Settings") {
                        Image(systemName: "slider.vertical.3").font(.system(size: 15)).foregroundStyle(.white)
                    } action: { open(.settings) }
                    .frame(width: 50)
                    divider
                    sizeFields.frame(maxWidth: .infinity)
                    divider
                    cell(.ratio, active: !ratio.isEmpty, help: "Aspect ratio") {
                        RatioGlyph(ratio: ratio)
                    } action: { open(.ratio) }
                    .frame(width: 50)
                }
                .frame(height: 40)
                Rectangle().fill(Self.line).frame(height: 1)
                HStack(spacing: 0) {
                    toggleCell(.mic, symbol: "mic", on: !micDevice.isEmpty, help: "Record Microphone", level: micDevice.isEmpty ? nil : mic.level) {
                        open(.mic)
                    }
                    divider
                    toggleCell(nil, symbol: "display", on: systemAudio, help: "Record System Audio", badge: "speaker.wave.2.fill") {
                        systemAudio.toggle()
                    }
                    divider
                    toggleCell(.camera, symbol: "video", on: !camera.isEmpty, help: "Show Camera") { open(.camera) }
                    divider
                    toggleCell(nil, symbol: "cursorarrow.rays", on: clicks, help: "Highlight Clicks") { clicks.toggle() }
                    divider
                    toggleCell(nil, symbol: "command.square", on: keystrokes, help: "Show Keystrokes") {
                        keystrokes.toggle()
                        // Without the permission it switches on, then explains and switches back off.
                        if keystrokes, !KeystrokePermission.isGranted {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                Defaults[Prefs.recShowKeystrokes] = false
                                KeystrokePermission.explain()
                            }
                        }
                    }
                }
                .frame(height: 40)
            }
            .background(Self.fill)
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(Self.line, lineWidth: 0.5))

            VStack(spacing: 0) {
                recordRow(gif: true, title: "Record GIF", keys: "⌥↩") { model.actions?.record(.gif) }
                Rectangle().fill(Self.line).frame(height: 1)
                recordRow(gif: false, title: "Record Video", keys: "↩") { model.actions?.record(.video) }
            }
            .background(Self.fill)
            .clipShape(RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Self.corner, style: .continuous).strokeBorder(Self.line, lineWidth: 0.5))

            StudioButton(model: model)
        }
        .frame(width: 253)
        .padding(10)
        .environment(\.colorScheme, .dark)
        .onAppear { MicLevel.shared.retain() }
        .onDisappear { MicLevel.shared.release() }
        .onChange(of: micDevice) { MicLevel.shared.update() }
    }

    private var divider: some View { Rectangle().fill(Self.line).frame(width: 1) }

    private var sizeFields: some View {
        HStack(spacing: 6) {
            SizeField(value: Int(model.size.width)) { model.actions?.resize(CGSize(width: CGFloat($0), height: model.size.height)) }
            Text("×").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            SizeField(value: Int(model.size.height)) { model.actions?.resize(CGSize(width: model.size.width, height: CGFloat($0))) }
            Button { model.actions?.fullScreen() } label: {
                Image(systemName: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white).frame(width: 15, height: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(red: 0x3E / 255.0, green: 0x3E / 255.0, blue: 0x3F / 255.0), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PanelPressStyle()).help("Toggle fullscreen")
        }
    }

    private func cell(_ anchor: Cell?, active: Bool, help: String, level: Double? = nil, @ViewBuilder content: () -> some View,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(alignment: .bottom) { if let level { LevelBand(level: level) } }
                .background(active ? Self.activeFill : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .background(anchor.map { AnchorView(cell: $0, model: model) })
        .help(help)
    }

    private func toggleCell(_ anchor: Cell?, symbol: String, on: Bool, help: String, badge: String? = nil, level: Double? = nil,
                            action: @escaping () -> Void) -> some View {
        // The cell darkens at once, the icon turns white and springs up ~5pt (slight
        // overshoot) while the checkmark fades in under it; switching off runs the same in reverse.
        cell(anchor, active: on, help: help, level: level) {
            ZStack {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: symbol).font(.system(size: 15))
                    if let badge {
                        Image(systemName: badge).font(.system(size: 7, weight: .bold)).offset(x: 6, y: -1)
                            .background(Circle().fill(on ? Self.activeFill : Self.fill).frame(width: 11, height: 11).offset(x: 6, y: -1)
                                .animation(nil, value: on))
                    }
                }
                .foregroundStyle(on ? Color.white : Self.gray)
                .animation(.easeOut(duration: 0.15), value: on)
                .offset(y: on ? -5 : 0)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .offset(y: 12)
                    .opacity(on ? 1 : 0)
                    .animation(.easeOut(duration: 0.18), value: on)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: on)
        } action: { action() }
    }

    private func recordRow(gif: Bool, title: String, keys: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Group {
                    if gif {
                        Text("GIF").font(.system(size: 8, weight: .black)).foregroundStyle(Self.fill)
                            .frame(width: 20, height: 13).background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white))
                    } else {
                        Image(systemName: "video.fill").font(.system(size: 13))
                    }
                }
                .frame(width: 24)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(keys).font(.system(size: 13, weight: .medium)).foregroundStyle(Self.gray)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
    }

    private func open(_ cell: Cell) {
        guard let anchor = model.anchors[cell] else { return }
        switch cell {
        case .settings: RecordSettingsPopover.show(from: anchor)
        case .ratio: RecordMenus.ratio(from: anchor) { model.actions?.ratioChanged() }
        case .mic: RecordMenus.microphone(from: anchor)
        case .camera: RecordMenus.camera(from: anchor)
        }
    }
}

/// The microphone meter: the cell's background fills from the bottom with a lighter gray
/// (#333 over #202021) up to the input level, stepping ~10× a second. Also used in the recording's stop button.
struct LevelBand: View {
    let level: Double
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(Color.white.opacity(0.085)).frame(height: geo.size.height * min(max(level, 0), 1))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
        .allowsHitTesting(false)
    }
}

/// Buttons dim slightly while pressed.
private struct PanelPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Remembers the cell's view so menus and the popover can open next to it.
private struct AnchorView: NSViewRepresentable {
    let cell: RecordPanel.Cell
    let model: RecordPanelModel
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        model.anchors[cell] = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { model.anchors[cell] = view }
}

/// The aspect-ratio glyph (recorder panel and All-In-One; filmed in All-In-One at ~40 fps): with Freeform the
/// 15pt crop icon is gray (like an off toggle) and centered. Picking a ratio turns it white and slides it up 5pt
/// (ease-out, ~0.15 s, no overshoot) while the ratio (white, 8.5pt semibold, 18pt wide for "16:9") fades in 12.5pt below the center; Freeform reverses it.
struct RatioGlyph: View {
    /// "" = Freeform.
    let ratio: String
    /// The last ratio shown, so the label can fade out with its text when Freeform is picked.
    @State private var shown = ""

    var body: some View {
        let on = !ratio.isEmpty
        ZStack {
            Image(systemName: "crop").font(.system(size: 14, weight: .medium))
                .foregroundStyle(on ? Color.white : RecordPanel.gray)
                .offset(y: on ? -5 : 0)
            Text(on ? ratio : (shown.isEmpty ? " " : shown)).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white)
                .fixedSize()
                .offset(y: 12.5)
                .opacity(on ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.15), value: on)
        .onAppear { shown = ratio }
        .onChange(of: ratio) { _, new in if !new.isEmpty { shown = new } }
    }
}

/// Editable width/height (points), 46×21pt on a darker field (All-In-One: 44×22).
struct SizeField: View {
    let value: Int
    var size = CGSize(width: 46, height: 21)
    var fill = RecordPanel.activeFill
    var weight: Font.Weight = .medium
    var textOpacity: Double = 1
    let commit: (Int) -> Void
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: weight))
            .foregroundStyle(.white.opacity(textOpacity))
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill))
            .onAppear { text = "\(value)" }
            .onChange(of: value) { _, v in text = "\(v)" }
            .onSubmit { if let v = Int(text), v >= 20 { commit(v) } else { text = "\(value)" } }
    }
}

/// "Record in Studio Mode": a capsule with a soft pink glow travelling around its edge (one loop ≈ 4 s). The "?"
/// explains what Studio Mode is.
private struct StudioButton: View {
    @ObservedObject var model: RecordPanelModel
    @State private var showsInfo = false

    var body: some View {
        // Two buttons side by side on one capsule: if the "?" sat on top of the record button, accessibility
        // (which finds controls by position) pressed the record button instead and started a recording.
        HStack(spacing: 0) {
            Button { model.actions?.record(.studio) } label: {
                HStack(spacing: 13) {
                    Image(systemName: "movieclapper.fill").font(.system(size: 13)).frame(width: 24)
                    Text("Record in Studio Mode").font(.system(size: 13, weight: .semibold)).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelPressStyle())
            .help("Record the screen as an editable project: zooms, cursor, clicks, keystrokes and camera can all be changed afterwards")
            Button { showsInfo.toggle() } label: {
                Image(systemName: "questionmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.white, Color.white.opacity(0.25))
                    .frame(width: 30, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(PanelPressStyle())
            .help("What is Studio Mode?")
            .accessibilityLabel("What is Studio Mode?")
            .padding(.trailing, 6)
            .popover(isPresented: $showsInfo, arrowEdge: .bottom) { StudioInfo() }
        }
        .foregroundStyle(.white)
        .frame(height: 40)
        .background(Capsule().fill(RecordPanel.fill))
        .overlay(Capsule().strokeBorder(RecordPanel.line, lineWidth: 0.5))
        .overlay(glow)
    }

    private var glow: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t.truncatingRemainder(dividingBy: 4) / 4) * 360)
            let pink = Color(red: 0.93, green: 0.33, blue: 0.47)
            Capsule()
                .strokeBorder(AngularGradient(colors: [pink.opacity(0), pink.opacity(0.9), pink.opacity(0), pink.opacity(0)],
                                              center: .center, angle: angle), lineWidth: 2)
                .blur(radius: 3)
                .allowsHitTesting(false)
        }
    }
}

/// "What is Studio Mode?": what it records and what can be changed afterwards.
private struct StudioInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "movieclapper.fill").font(.system(size: 15)).foregroundStyle(.pink)
                Text("What is Studio Mode?").font(.system(size: 14, weight: .semibold))
            }
            Text("Studio Mode records your screen as an editable project, so you keep full control after recording. "
                 + "Add smooth zooms that follow the cursor, change the cursor and click effects, show keystrokes and place your camera — "
                 + "then export a polished video.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 7) {
                row("plus.magnifyingglass", "Automatic zooms that follow your cursor")
                row("cursorarrow.motionlines", "Smooth cursor, size, style and click effects")
                row("command.square", "Keystrokes, styled after recording")
                row("video", "Camera size, shape and position")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
            Text(text).font(.system(size: 12.5))
        }
    }
}

// MARK: - Menus

/// The native menus of the ratio, microphone and camera cells, opening just below the cell.
enum RecordMenus {
    private static func popUp(_ menu: NSMenu, below view: NSView) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 6 : -6), in: view)
    }

    private static func header(_ title: String) -> NSMenuItem { .sectionHeader(title: title) }

    static func ratio(from view: NSView, pref: Pref<String> = Prefs.recRatio, changed: @escaping () -> Void) {
        let current = Defaults[pref]
        let menu = NSMenu()
        let set: (String) -> Void = { Defaults[pref] = $0; changed() }
        let freeform = ClosureMenuItem(title: "Freeform") { set("") }
        freeform.state = current.isEmpty ? .on : .off
        menu.addItem(freeform)
        menu.addItem(.separator())
        for group in [RecordRatio.landscape, RecordRatio.portrait] {
            for r in group {
                let item = ClosureMenuItem(title: r.title) { set(r.key) }
                item.state = r.key == current ? .on : .off
                menu.addItem(item)
            }
            if group.count == RecordRatio.landscape.count { menu.addItem(.separator()) }
        }
        popUp(menu, below: view)
    }

    static func microphone(from view: NSView) {
        let current = Defaults[Prefs.recMicDevice]
        let menu = NSMenu()
        let none = ClosureMenuItem(title: "Do Not Record Microphone") { Defaults[Prefs.recMicDevice] = "" }
        none.state = current.isEmpty ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())
        for device in devices(.audio) {
            let item = ClosureMenuItem(title: device.localizedName) {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async { if granted { Defaults[Prefs.recMicDevice] = device.uniqueID } }
                }
            }
            item.state = device.uniqueID == current ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, below: view)
    }

    static func camera(from view: NSView) {
        let current = Defaults[Prefs.recCamera]
        let menu = NSMenu()
        func check(_ item: NSMenuItem, _ on: Bool) -> NSMenuItem { item.state = on ? .on : .off; return item }
        menu.addItem(header("Camera"))
        menu.addItem(check(ClosureMenuItem(title: "None") { Defaults[Prefs.recCamera] = ""; WebcamOverlay.shared.update() }, current.isEmpty))
        for device in devices(.video) {
            menu.addItem(check(ClosureMenuItem(title: device.localizedName) {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    DispatchQueue.main.async {
                        guard granted else { return }
                        Defaults[Prefs.recCamera] = device.uniqueID
                        WebcamOverlay.shared.update()
                    }
                }
            }, device.uniqueID == current))
        }
        menu.addItem(.separator())
        menu.addItem(header("Size"))
        for (i, title) in WebcamOverlay.sizeTitles.enumerated() {
            menu.addItem(check(ClosureMenuItem(title: title) { Defaults[Prefs.recCameraSize] = i; WebcamOverlay.shared.update() },
                               Defaults[Prefs.recCameraSize] == i))
        }
        menu.addItem(.separator())
        menu.addItem(header("Click on camera to toggle Full Screen"))
        menu.addItem(check(ClosureMenuItem(title: "Full Screen") { WebcamOverlay.shared.toggleFullScreen() }, WebcamOverlay.shared.isFullScreen))
        menu.addItem(.separator())
        menu.addItem(header("Shape"))
        for (i, title) in WebcamOverlay.shapeTitles.enumerated() {
            menu.addItem(check(ClosureMenuItem(title: title) { Defaults[Prefs.recCameraShape] = i; WebcamOverlay.shared.update() },
                               Defaults[Prefs.recCameraShape] == i))
        }
        menu.addItem(.separator())
        menu.addItem(header("Options"))
        menu.addItem(check(ClosureMenuItem(title: "Flip Camera") { Defaults[Prefs.recCameraFlip].toggle(); WebcamOverlay.shared.update() },
                           Defaults[Prefs.recCameraFlip]))
        popUp(menu, below: view)
    }

    static func devices(_ type: AVMediaType) -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = type == .audio ? [.microphone] : [.builtInWideAngleCamera, .continuityCamera, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: type, position: .unspecified).devices
    }
}

/// Keystrokes need the keyboard-monitoring permission; without it Glint explains where to grant it.
enum KeystrokePermission {
    static var isGranted: Bool { CGPreflightListenEventAccess() }

    static func ensure() -> Bool {
        if isGranted { return true }
        explain()
        return false
    }

    /// Asks for the permission (adds Glint to the list) and explains where to turn it on.
    static func explain() {
        CGRequestListenEventAccess()
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Glint needs Device Control and Data Access permissions to display keystrokes while recording"
        alert.informativeText = "To grant them, go to System Settings > Privacy & Security > Device Control and Data Access > click the (+) button, and choose Glint from the list."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
    }
}

// MARK: - Settings popover

/// The settings cell opens the full Recording settings in a popover that grows out of the button (406×526pt).
enum RecordSettingsPopover {
    private static var popover: NSPopover?

    static func show(from view: NSView) {
        if let popover, popover.isShown { popover.close(); return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingController(rootView: RecordingSettingsView(compact: true).frame(width: 406, height: 526))
        host.sizingOptions = []
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 406, height: 526)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
        self.popover = popover
    }
}
