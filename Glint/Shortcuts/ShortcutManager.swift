import AppKit
import Carbon.HIToolbox
import Observation

/// Stores the user's global shortcuts and registers them with the system (Carbon hot keys still work
/// without Accessibility permission, unlike event taps).
@Observable
final class ShortcutManager {
    static let shared = ShortcutManager()

    var onTrigger: ((AppAction) -> Void)?

    /// Shortcuts currently assigned. Missing key = no shortcut.
    private(set) var shortcuts: [AppAction: KeyCombo] = [:]

    @ObservationIgnored private var hotKeyRefs: [AppAction: EventHotKeyRef] = [:]
    @ObservationIgnored private var handlerRef: EventHandlerRef?
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var escapeRef: EventHotKeyRef?
    @ObservationIgnored private var escapeHandler: (() -> Void)?
    private static let escapeID: UInt32 = 9_999

    private init() {
        for action in AppAction.allCases {
            if let stored = UserDefaults.standard.string(forKey: Self.storageKey(action)) {
                if let combo = KeyCombo(storageString: stored) { shortcuts[action] = combo }
            } else if let combo = action.defaultShortcut {
                shortcuts[action] = combo
            }
        }
    }

    func start() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyHandler, 1, &eventType, nil, &handlerRef)
        registerAll()
    }

    func shortcut(for action: AppAction) -> KeyCombo? { shortcuts[action] }

    func set(_ combo: KeyCombo?, for action: AppAction) {
        // A combo can only belong to one action.
        if let combo, let other = shortcuts.first(where: { $0.value == combo && $0.key != action })?.key {
            set(nil, for: other)
        }
        shortcuts[action] = combo
        UserDefaults.standard.set(combo?.storageString ?? "", forKey: Self.storageKey(action))
        register(action)
    }

    func restoreDefaults() {
        for action in AppAction.allCases {
            UserDefaults.standard.removeObject(forKey: Self.storageKey(action))
            shortcuts[action] = action.defaultShortcut
        }
        registerAll()
    }

    /// Disables global hot keys while a shortcut recorder is listening.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        registerAll()
    }

    /// Claims the Escape key system-wide while a capture overlay is up, so it can always be cancelled
    /// even if the overlay never became the key window. Pass nil to release it.
    func setEscapeHandler(_ handler: (() -> Void)?) {
        if let ref = escapeRef { UnregisterEventHotKey(ref) }
        escapeRef = nil
        escapeHandler = handler
        guard handler != nil else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x474C_4E54), id: Self.escapeID)
        if RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &ref) == noErr { escapeRef = ref }
    }

    fileprivate func fire(id: UInt32) {
        if id == Self.escapeID { escapeHandler?(); return }
        guard let action = AppAction.allCases.first(where: { Self.hotKeyID($0) == id }) else { return }
        onTrigger?(action)
    }

    private func registerAll() {
        for action in AppAction.allCases { register(action) }
    }

    private func register(_ action: AppAction) {
        if let ref = hotKeyRefs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
        guard !isSuspended, let combo = shortcuts[action] else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x474C_4E54) /* 'GLNT' */, id: Self.hotKeyID(action))
        let status = RegisterEventHotKey(combo.key.code, combo.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { hotKeyRefs[action] = ref } else {
            glintLog("could not register \(combo.displayString) for \(action.rawValue) (\(status))")
        }
    }

    private static func storageKey(_ action: AppAction) -> String { "shortcut.\(action.rawValue)" }

    private static func hotKeyID(_ action: AppAction) -> UInt32 {
        UInt32(AppAction.allCases.firstIndex(of: action)! + 1)
    }
}

private nonisolated func hotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    MainActor.assumeIsolated { ShortcutManager.shared.fire(id: id) }
    return noErr
}
