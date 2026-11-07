import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(SettingsModel.self) private var model
    private var search: String { model.shortcutSearch }
    @State private var systemShortcuts = SystemScreenshotShortcuts.conflicting

    private var sections: [ShortcutSection] {
        guard !search.isEmpty else { return ShortcutSection.all }
        return ShortcutSection.all.compactMap { section in
            let groups = section.groups.map { $0.filter { $0.title.localizedCaseInsensitiveContains(search) } }.filter { !$0.isEmpty }
            return groups.isEmpty ? nil : ShortcutSection(title: section.title, symbol: section.symbol, groups: groups)
        }
    }

    var body: some View {
        Form {
            if search.isEmpty, !systemShortcuts.isEmpty { systemShortcutsSection }
            ForEach(sections) { section in
                ForEach(Array(section.groups.enumerated()), id: \.offset) { index, group in
                    Section {
                        ForEach(group) { action in
                            LabeledContent(action.title) { ShortcutRecorder(action: action) }
                        }
                    } header: {
                        if index == 0 { Label(section.title, systemImage: section.symbol) }
                    }
                }
            }

            if search.isEmpty || "New Tab".localizedCaseInsensitiveContains(search) {
                Section {
                    LabeledContent {
                        NewTabShortcutRecorder()
                    } label: {
                        Text("New Tab")
                        Text("Opens a capture in a new tab of the screenshot or video editor. Works while an editor is in front.")
                    }
                } header: {
                    Label("Editors", systemImage: "macwindow.on.rectangle")
                }
            }

            if search.isEmpty {
                Section("Options") {
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { ShortcutManager.shared.restoreDefaults() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemShortcuts = SystemScreenshotShortcuts.conflicting
        }
    }

    /// macOS's own screenshot shortcuts are still on: they win over Glint's ⇧⌘3, ⇧⌘4, ⇧⌘5 and ⌃⇧⌘4.
    private var systemShortcutsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("macOS's screenshot shortcuts are still on", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .symbolRenderingMode(.multicolor)
                Text("While they're on, macOS takes these keys and Glint's shortcuts don't work. Open System Settings → Keyboard, click Keyboard Shortcuts…, choose Screenshots on the left and uncheck:")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(systemShortcuts) { shortcut in
                        Text("• \(shortcut.title) (\(shortcut.keys))")
                    }
                }
                .padding(.leading, 4)
                HStack {
                    Spacer()
                    Button("Open Keyboard Settings…") { SystemScreenshotShortcuts.openSettings() }
                    Button("Check Again") { systemShortcuts = SystemScreenshotShortcuts.conflicting }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
