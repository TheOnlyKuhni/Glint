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
        // Started by the user (Spotlight, Finder, Launchpad): the menu bar menu opens, as when Glint was already
        // running. Not when started for a file or link, by the glint command (`--background`), or at login.
        let isDefault = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? false
        let startedByUser = isDefault && !ProcessInfo.processInfo.arguments.contains("--background") && !Self.launchedAtLogin
        if startedByUser { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in _ = self?.statusItemController?.openMenu() } }
    }

    /// Launch at login (or the windows reopened at login) starts Glint in the first minutes after the Mac starts up
    /// or the user logs in. Logging in can take longer than any time since startup (FileVault, slow sign-in), so
    /// the time counts from the user's session start: when the Dock started, which happens at login.
    private static var launchedAtLogin: Bool {
        let window: TimeInterval = 240
        if ProcessInfo.processInfo.systemUptime < window { return true }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let started = processStart(dock.processIdentifier) else { return false }
        return Date().timeIntervalSince(started) < window
    }

    private static func processStart(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
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
    /// icon is hidden, so there's still a way in. With an editor open, that editor comes forward instead (as any
    /// app's windows do), and the menu stays closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let editors = NSApp.windows.filter { window in
            (window.windowController is AnnotateWindowController || window.windowController is VideoEditorWindowController
                || window.windowController is GIFTrimmer) && (window.isVisible || window.isMiniaturized)
        }
        if !editors.isEmpty {
            NSApp.bringToFront()
            let window = editors.first { $0.isVisible } ?? editors[0]
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }
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
        appMenu.addItem(withTitle: "About Glint", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppMenuTarget.checkForUpdates), keyEquivalent: "").target = AppMenuTarget.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(AppMenuTarget.openSettings), keyEquivalent: ",").target = AppMenuTarget.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Glint", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
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
        // Both editors: Save; Save As… (the video editor's Export…).
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

        // The screenshot editor's zoom (the same shortcuts as its zoom menu).
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Zoom In", action: #selector(AnnotateWindowController.zoomInFromMenu(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(AnnotateWindowController.zoomOutFromMenu(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(AnnotateWindowController.actualSizeFromMenu(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(AnnotateWindowController.zoomToFitFromMenu(_:)), keyEquivalent: "9")
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
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
    @objc func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc func openAnnotate() { AnnotateWindowController.openFromPanel() }
}
