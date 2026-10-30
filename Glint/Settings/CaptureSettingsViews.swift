import SwiftUI

struct QuickAccessSettingsView: View {
    @AppStorage(Prefs.quickAccessPosition) private var position
    @AppStorage(Prefs.quickAccessMoveToActiveScreen) private var moveToActiveScreen
    @AppStorage(Prefs.quickAccessSize) private var size
    @AppStorage(Prefs.quickAccessAutoClose) private var autoClose
    @AppStorage(Prefs.quickAccessAutoCloseAction) private var autoCloseAction
    @AppStorage(Prefs.quickAccessAutoCloseInterval) private var autoCloseInterval
    @AppStorage(Prefs.quickAccessCloseAfterDragging) private var closeAfterDragging
    @AppStorage(Prefs.quickAccessSaveBehavior) private var saveBehavior

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Position on screen", selection: $position) {
                    ForEach(ScreenSide.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $moveToActiveScreen) {
                    Text("Move to active screen")
                    Text("Active screen is the screen where your cursor is pointing.")
                }
                LabeledContent("Overlay size") {
                    Slider(value: $size, in: 0...4, step: 1).frame(width: 210)
                }
            }

            Section("Behavior") {
                Toggle("Auto-close", isOn: $autoClose)
                Picker("Action", selection: $autoCloseAction) {
                    ForEach(AutoCloseAction.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!autoClose)
                Picker("Interval", selection: $autoCloseInterval) {
                    ForEach([5, 10, 15, 30, 60, 120, 300], id: \.self) { Text(Self.intervalTitle($0)).tag($0) }
                }
                .disabled(!autoClose)
            }

            Section {
                Toggle(isOn: $closeAfterDragging) {
                    Text("Close after dragging")
                    Text("Hold ⌥ (option) to keep the item on Overlay after dragging.")
                }
                Picker(selection: $saveBehavior) {
                    ForEach(SaveButtonBehavior.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Save button behavior")
                    Text("Press with ⌥ (option) to choose the destination.")
                }
            }
        }
        .formStyle(.grouped)
    }

    static func intervalTitle(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")
    }
}

struct WallpaperSettingsView: View {
    @AppStorage(Prefs.wallpaperSource) private var source
    @AppStorage(Prefs.wallpaperCustomPath) private var customPath
    @AppStorage(Prefs.wallpaperColor) private var colorHex
    @AppStorage(Prefs.wallpaperUpdateOnSpaceSwitch) private var updateOnSpaceSwitch

    var body: some View {
        Form {
            Section("Desktop") {
                Picker(selection: $source) {
                    ForEach(WallpaperSource.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Wallpaper")
                    Text("Set a custom wallpaper used to hide desktop icons and as the background behind window screenshots.")
                }
                if source == .custom {
                    LabeledContent("Image") {
                        HStack {
                            Text(customPath.isEmpty ? "None" : (customPath as NSString).lastPathComponent).foregroundStyle(.secondary)
                            Button("Choose…", action: chooseImage)
                        }
                    }
                }
                if source == .color {
                    ColorPicker("Color", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: colorHex) ?? .systemBlue) },
                        set: { colorHex = NSColor($0).hexString }
                    ), supportsOpacity: false)
                }
                Toggle("Update wallpaper when switching Spaces", isOn: $updateOnSpaceSwitch)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
    }
}

struct ScreenshotsSettingsView: View {
    @AppStorage(Prefs.fileFormat) private var format
    @AppStorage(Prefs.convertToSRGB) private var convertToSRGB
    @AppStorage(Prefs.scaleRetinaTo1x) private var scaleTo1x
    @AppStorage(Prefs.addBorder) private var addBorder
    @AppStorage(Prefs.backgroundPreset) private var backgroundPreset
    @AppStorage(Prefs.selfTimerInterval) private var selfTimerInterval
    @AppStorage(Prefs.showCursor) private var showCursor
    @AppStorage(Prefs.freezeScreen) private var freezeScreen
    @AppStorage(Prefs.windowBackground) private var windowBackground
    @AppStorage(Prefs.windowPadding) private var windowPadding
    @AppStorage(Prefs.windowShadow) private var windowShadow
    @AppStorage(Prefs.crosshairMode) private var crosshairMode
    @AppStorage(Prefs.showMagnifier) private var showMagnifier

    var body: some View {
        Form {
            Section("Output") {
                Picker("File format", selection: $format) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Convert to sRGB profile", isOn: $convertToSRGB)
                Toggle("Scale Retina screenshots to 1x", isOn: $scaleTo1x)
                Toggle("Add 1px border to all screenshots", isOn: $addBorder)
                Picker(selection: $backgroundPreset) {
                    Text("None").tag(-1)
                    ForEach(Array(BackgroundStyle.presets.enumerated()), id: \.offset) { i, preset in
                        Text(preset.name ?? "Preset \(i + 1)").tag(i)
                    }
                } label: {
                    Text("Background preset")
                    Text("Apply Background Tool preset to all screenshots. You can create presets in Annotate. Hold ⇧ Shift while capturing a screenshot to disable this option.")
                }
            }

            Section("Capture") {
                Picker("Timer interval", selection: $selfTimerInterval) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) Seconds").tag($0) }
                }
                Toggle(isOn: $showCursor) {
                    Text("Show cursor on screenshots")
                    Text("This works in Fullscreen or Timer modes only.")
                }
                Toggle("Freeze screen when taking a screenshot", isOn: $freezeScreen)
            }

            Section("Window Screenshots") {
                LabeledContent {
                    HStack(spacing: 16) {
                        BackgroundChoice(title: "With wallpaper", transparent: false, selected: windowBackground == .wallpaper) {
                            windowBackground = .wallpaper
                        }
                        BackgroundChoice(title: "Transparent", transparent: true, selected: windowBackground == .transparent) {
                            windowBackground = .transparent
                        }
                    }
                } label: {
                    Text("Background")
                    Text("Hold ⇧ Shift while taking a screenshot to get a transparent background. You can customize the wallpaper in [wallpaper settings](glint-settings://wallpaper).")
                }
                // A transparent window screenshot has no padding (just the window and its shadow).
                if windowBackground != .transparent {
                    LabeledContent("Padding") {
                        Slider(value: $windowPadding, in: 0...6, step: 1).frame(width: 210)
                    }
                }
                Toggle("Capture window shadow", isOn: $windowShadow)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset Defaults") {
                        windowBackground = Prefs.windowBackground.defaultValue
                        windowPadding = Prefs.windowPadding.defaultValue
                        windowShadow = Prefs.windowShadow.defaultValue
                    }
                }
            }

            Section("Crosshair") {
                Picker("Crosshair Mode", selection: $crosshairMode) {
                    ForEach(CrosshairMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $showMagnifier) {
                    Text("Show magnifier")
                    Text("To enable magnifier, you must enable Crosshair Mode first.")
                }
                .disabled(crosshairMode == .disabled)
            }
        }
        .formStyle(.grouped)
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "glint-settings", let pane = SettingsPane(rawValue: url.host() ?? "") {
                SettingsWindowController.shared.show(pane: pane)
                return .handled
            }
            return .systemAction
        })
    }
}

/// Thumbnail button for the window screenshot background choice.
private struct BackgroundChoice: View {
    let title: String
    let transparent: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if transparent {
                        Checkerboard()
                    } else {
                        LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.2), Color(red: 0.93, green: 0.35, blue: 0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    MiniWindow().padding(.horizontal, 14).padding(.vertical, 16)
                }
                .frame(width: 96, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                        .padding(-4)
                )
                Text(title).font(.callout).foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct MiniWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(.red).frame(width: 5)
                Circle().fill(.yellow).frame(width: 5)
                Circle().fill(.green).frame(width: 5)
                Spacer()
            }
            .padding(.horizontal, 5)
            .frame(height: 11)
            Rectangle().fill(Color(white: 0.96))
        }
        .background(Color(white: 0.92))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for row in 0..<Int(size.height / s) + 1 {
                for col in 0..<Int(size.width / s) + 1 where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)), with: .color(Color(white: 0.55)))
                }
            }
        }
        .background(Color(white: 0.4))
    }
}
