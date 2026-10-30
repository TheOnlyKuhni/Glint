import AppKit
import Carbon.HIToolbox

/// A key plus modifier flags, e.g. ⌥⇧⌘4.
struct KeyCombo: Equatable, Hashable {
    struct Key: Equatable, Hashable {
        let code: UInt32
        static let two = Key(code: UInt32(kVK_ANSI_2))
        static let three = Key(code: UInt32(kVK_ANSI_3))
        static let four = Key(code: UInt32(kVK_ANSI_4))
        static let five = Key(code: UInt32(kVK_ANSI_5))
    }

    let key: Key
    let modifiers: NSEvent.ModifierFlags

    init(key: Key, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.init(key: Key(code: UInt32(event.keyCode)), modifiers: event.modifierFlags)
    }

    static func == (lhs: KeyCombo, rhs: KeyCombo) -> Bool {
        lhs.key == rhs.key && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    // MARK: Persistence ("code:modifiers")

    var storageString: String { "\(key.code):\(modifiers.rawValue)" }

    init?(storageString: String) {
        let parts = storageString.split(separator: ":")
        guard parts.count == 2, let code = UInt32(parts[0]), let mods = UInt(parts[1]) else { return nil }
        self.init(key: Key(code: code), modifiers: NSEvent.ModifierFlags(rawValue: mods))
    }

    // MARK: Carbon

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    // MARK: Display

    var modifierSymbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    var keySymbol: String { Self.name(for: key.code) }

    /// e.g. "⌥ ⇧ ⌘ 4", spaced like the recorder buttons in settings.
    var displayString: String {
        (modifierSymbols.map(String.init) + [keySymbol]).joined(separator: " ")
    }

    /// Character for NSMenuItem.keyEquivalent.
    var menuKeyEquivalent: String {
        if let special = Self.menuSpecialKeys[Int(key.code)] { return String(Character(UnicodeScalar(special)!)) }
        return Self.name(for: key.code).lowercased()
    }

    /// Whether this combo is acceptable as a global shortcut (needs a modifier unless it is a function key).
    var isValidGlobalShortcut: Bool {
        !modifiers.isEmpty || Self.functionKeys.contains(Int(key.code))
    }

    private static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                                 kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                                 kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    private static let specialNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20",
    ]

    private static let menuSpecialKeys: [Int: Int] = [
        kVK_Return: 0x0D, kVK_Tab: 0x09, kVK_Space: 0x20, kVK_Delete: 0x08, kVK_Escape: 0x1B,
        kVK_LeftArrow: NSLeftArrowFunctionKey, kVK_RightArrow: NSRightArrowFunctionKey,
        kVK_UpArrow: NSUpArrowFunctionKey, kVK_DownArrow: NSDownArrowFunctionKey,
        kVK_F1: NSF1FunctionKey, kVK_F2: NSF2FunctionKey, kVK_F3: NSF3FunctionKey, kVK_F4: NSF4FunctionKey,
        kVK_F5: NSF5FunctionKey, kVK_F6: NSF6FunctionKey, kVK_F7: NSF7FunctionKey, kVK_F8: NSF8FunctionKey,
        kVK_F9: NSF9FunctionKey, kVK_F10: NSF10FunctionKey, kVK_F11: NSF11FunctionKey, kVK_F12: NSF12FunctionKey,
    ]

    /// Layout-aware key name (so a German keyboard shows ß, ´, etc.).
    static func name(for code: UInt32) -> String {
        if let special = specialNames[Int(code)] { return special }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return "?" }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return "?" }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}
