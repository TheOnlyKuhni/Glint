import AppKit

/// macOS's own screenshot shortcuts (System Settings → Keyboard → Keyboard Shortcuts → Screenshots). While they're on,
/// macOS handles ⇧⌘3, ⇧⌘4 and ⇧⌘5 itself and Glint's default shortcuts never fire.
enum SystemScreenshotShortcuts {
    struct Shortcut: Identifiable {
        /// The key in `com.apple.symbolichotkeys`.
        let id: Int
        let keys: String
        let title: String
    }

    /// Titles as System Settings shows them.
    static let all: [Shortcut] = [
        Shortcut(id: 28, keys: "⇧⌘3", title: "Save picture of screen as a file"),
        Shortcut(id: 29, keys: "⌃⇧⌘3", title: "Copy picture of screen to the clipboard"),
        Shortcut(id: 30, keys: "⇧⌘4", title: "Save picture of selected area as a file"),
        Shortcut(id: 31, keys: "⌃⇧⌘4", title: "Copy picture of selected area to the clipboard"),
        Shortcut(id: 184, keys: "⇧⌘5", title: "Screenshot and recording options"),
    ]

    /// The ones still switched on that take keys Glint uses. A shortcut missing from the preferences has never been
    /// changed, so it's on. (Assumes macOS's default keys for them, which almost nobody changes.)
    static var conflicting: [Shortcut] {
        let glintKeys = Set(ShortcutManager.shared.shortcuts.values.map { $0.modifierSymbols + $0.keySymbol })
        return enabled.filter { glintKeys.contains($0.keys) }
    }

    static var enabled: [Shortcut] {
        CFPreferencesAppSynchronize("com.apple.symbolichotkeys" as CFString)
        let hotKeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return all.filter { shortcut in
            guard let entry = hotKeys?[String(shortcut.id)] as? [String: Any] else { return true }
            return (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int).map { $0 != 0 } ?? true)
        }
    }

    /// Opens System Settings → Keyboard (Keyboard Shortcuts… is a button there).
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}
