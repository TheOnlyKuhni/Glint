import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(SettingsModel.self) private var model
    private var search: String { model.shortcutSearch }

    private var sections: [ShortcutSection] {
        guard !search.isEmpty else { return ShortcutSection.all }
        return ShortcutSection.all.compactMap { section in
            let groups = section.groups.map { $0.filter { $0.title.localizedCaseInsensitiveContains(search) } }.filter { !$0.isEmpty }
            return groups.isEmpty ? nil : ShortcutSection(title: section.title, symbol: section.symbol, groups: groups)
        }
    }

    var body: some View {
        Form {
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
    }
}
