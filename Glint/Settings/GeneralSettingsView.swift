import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon
    @AppStorage(Prefs.hideDesktopIconsWhileCapturing) private var hideDesktopIcons
    @AppStorage(Prefs.playSounds) private var playSounds
    @AppStorage(Prefs.shutterSound) private var shutterSound
    @AppStorage(Prefs.exportLocation) private var exportLocation
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var checkForUpdates = Updater.shared.automaticallyChecks

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(isOn: $showMenuBarIcon) {
                    Text("Show menu bar icon")
                    Text("Glint keeps running without it and shortcuts still work. Open Glint again from your Applications folder to get back here; ⌘Q quits it from this window.")
                }
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $checkForUpdates)
                    .onChange(of: checkForUpdates) { _, on in Updater.shared.automaticallyChecks = on }
                    .disabled(!Updater.shared.isConfigured)
                LabeledContent("Version \(Bundle.main.shortVersion)") {
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                }
            }

            Section("Capture") {
                Toggle(isOn: $hideDesktopIcons) {
                    Text("Hide desktop icons while capturing")
                    Text("You can set a custom wallpaper to hide desktop icons in [wallpaper settings](glint-settings://wallpaper).")
                }
            }

            Section("Sounds") {
                Toggle("Play sounds", isOn: $playSounds)
                Picker("Shutter sound", selection: $shutterSound) {
                    ForEach(ShutterSound.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: shutterSound) { _, sound in SoundPlayer.play(sound) }
            }

            Section("Export") {
                LabeledContent("Export location") {
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: FileSaver.exportDirectory.path))
                                .resizable().frame(width: 16, height: 16)
                            Text(FileManager.default.displayName(atPath: FileSaver.exportDirectory.path))
                                .foregroundStyle(.secondary)
                        }
                        Button("Choose…", action: chooseExportLocation)
                    }
                }
                Text("Set the default save location used when saving from the Quick Access Overlay, After Capture, and other Save actions across the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                AfterCaptureTable()
            } header: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("After Capture")
                    Text("Decide what should happen after taking a screenshot or recording a video.")
                        .font(.callout).fontWeight(.regular).foregroundStyle(.secondary)
                }
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

    private func chooseExportLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = FileSaver.exportDirectory
        if panel.runModal() == .OK, let url = panel.url { exportLocation = url.path }
    }
}

/// The Action / Screenshot / Recording checkbox grid.
private struct AfterCaptureTable: View {
    private let columnWidth: CGFloat = 110

    var body: some View {
        HStack {
            Text("Action")
            Spacer()
            Text("Screenshot").frame(width: columnWidth)
            Text("Recording").frame(width: columnWidth)
        }
        .foregroundStyle(.secondary)

        ForEach(AfterCaptureAction.allCases) { action in
            HStack {
                Text(action.title)
                Spacer()
                cell(action, .screenshot)
                cell(action, .recording)
            }
        }
    }

    @ViewBuilder
    private func cell(_ action: AfterCaptureAction, _ kind: CaptureKind) -> some View {
        Group {
            if action.applies(to: kind) {
                PrefCheckbox(pref: Prefs.afterCapture(action, kind))
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .frame(width: columnWidth)
    }
}

private struct PrefCheckbox: View {
    @AppStorage private var value: Bool
    init(pref: Pref<Bool>) { _value = AppStorage(pref) }
    var body: some View {
        Toggle("", isOn: $value).toggleStyle(.checkbox).labelsHidden()
    }
}
