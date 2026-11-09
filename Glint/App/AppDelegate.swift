import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // Native tooltips (.help, toolTip) appear after 1 s like Glint's own hints (the system default is slower).
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 1000])
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        NSApp.servicesProvider = self
        statusItemController = StatusItemController()
        ShortcutManager.shared.onTrigger = { action in AppRouter.perform(action) }
        ShortcutManager.shared.start()
        HistoryStore.shared.prune()
        // Glint can run for weeks: "Keep history" can't wait for the next launch.
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { HistoryStore.shared.prune() }
        }
        _ = Updater.shared
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            // A file: Finder's Open With, or dropped on the Dock icon.
            if url.isFileURL { AnnotateWindowController.open(url: url) } else { AppRouter.handle(url: url) }
        }
    }

    /// The "Open in Glint Annotate" service: Finder's right-click menu (Quick Actions / Services).
    @objc func openInAnnotate(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { error.pointee = "No image files were selected." as NSString; return }
        urls.forEach { AnnotateWindowController.open(url: $0) }
    }

    /// Opening Glint again (Spotlight, Finder, the Dock) opens its menu bar menu; Settings only when the menu bar
    /// icon is hidden, so there's still a way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // With an editor or Settings open, reopening just brings those forward (macOS does that).
        if NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }) { return true }
        if statusItemController?.openMenu() != true { SettingsWindowController.shared.show() }
        return true
    }
}

/// Routes actions from shortcuts, the menu bar and the URL scheme.
enum AppRouter {
    static func perform(_ action: AppAction) {
        CaptureCoordinator.shared.perform(action)
    }

    /// `glint://capture-area`, `glint://open-settings`, `glint://pin?filepath=…`, …
    static func handle(url: URL) {
        guard url.scheme == "glint", Defaults[Prefs.allowURLScheme] else { return }
        let command = url.host() ?? ""
        glintLog("url \(url.absoluteString)")
        #if DEBUG
        let query = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
        if DebugHooks.handle(command, query) { return }
        #endif
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let path = items.first { $0.name == "filepath" }?.value
        // The `glint` command-line tool asks for an answer (see CLIReply).
        CLIReply.begin(items.first { $0.name == "reply" }?.value)
        if let path, ["open-annotate", "open-video-editor", "pin"].contains(command),
           !FileManager.default.fileExists(atPath: path) {
            CLIReply.error("no file at \(path)")
            NSSound.beep()
            return
        }
        if command == "open-settings" {
            SettingsWindowController.shared.show()
        } else if command == "open-annotate" {
            if let path { AnnotateWindowController.open(url: URL(fileURLWithPath: path)) } else { AnnotateWindowController.openFromPanel() }
        } else if command == "open-video-editor" {
            if let path { VideoEditorWindowController.open(url: URL(fileURLWithPath: path)) } else { VideoEditorWindowController.openFromPanel() }
        } else if command == "pin" {
            if let path, let item = CaptureItem.load(URL(fileURLWithPath: path)) { PinManager.shared.pin(item) } else { PinManager.shared.pinFromPanel() }
        } else if let action = AppAction.allCases.first(where: { $0.urlCommand == command }) {
            if CLIReply.answersLater(action), !Permissions.hasScreenRecording {
                CLIReply.error("Glint needs the Screen Recording permission (System Settings → Privacy & Security)")
            }
            perform(action)
            if !CLIReply.answersLater(action) { CLIReply.send("ok") }
            return
        } else {
            CLIReply.error("unknown command \(command)")
            NSSound.beep()
            return
        }
        CLIReply.send("ok")
    }
}

/// A minimal main menu so standard shortcuts (copy/paste, close window) work in Glint's windows.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppMenuTarget.openSettings), keyEquivalent: ",").target = AppMenuTarget.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(AppMenuTarget.openAnnotate), keyEquivalent: "o").target = AppMenuTarget.shared
        // Handled by the editor windows (and New Tab's chooser); shown greyed out elsewhere.
        let newTab = file.addItem(withTitle: "New Tab", action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "")
        newTabItem = newTab
        updateNewTabShortcut()
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(AnnotateWindowController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(AnnotateWindowController.saveDocumentAs(_:)), keyEquivalent: "S")
        file.addItem(withTitle: "Copy Screenshot", action: #selector(AnnotateWindowController.copyScreenshot(_:)), keyEquivalent: "C")
        file.addItem(withTitle: "Add Screenshot", action: #selector(AnnotateWindowController.addScreenshot(_:)), keyEquivalent: "I")
        file.addItem(withTitle: "Add Image From File…", action: #selector(AnnotateWindowController.addImageFromFile(_:)), keyEquivalent: "i")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        // AppKit adds the tab commands (Show Tab Bar, Show All Tabs, Merge All Windows…) to the Window menu.
        NSApp.windowsMenu = window
        return main
    }

    private static weak var newTabItem: NSMenuItem?

    /// The New Tab shortcut from Settings → Shortcuts (⌘T by default).
    static func updateNewTabShortcut() {
        guard let item = newTabItem else { return }
        let combo = KeyCombo(storageString: Defaults[Prefs.editorNewTabShortcut])
        item.keyEquivalent = combo?.menuKeyEquivalent ?? ""
        item.keyEquivalentModifierMask = combo?.modifiers ?? []
    }
}

final class AppMenuTarget: NSObject {
    static let shared = AppMenuTarget()
    @objc func openSettings() { SettingsWindowController.shared.show() }
    @objc func openAnnotate() { AnnotateWindowController.openFromPanel() }
}
