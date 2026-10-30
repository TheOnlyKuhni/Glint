import AppKit

/// The menu bar icon and its menu.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        super.init()
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.setAccessibilityTitle("Glint")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateVisibility()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        recordingObserver = NotificationCenter.default.addObserver(forName: .recordingStateChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRecording() }
        }
    }

    private var recordingObserver: NSObjectProtocol?

    /// While recording: a stop icon (and the time, "Display recording time in menu bar"); a click stops.
    private func updateRecording() {
        guard let button = statusItem.button else { return }
        if RecordingController.shared.isRecording {
            statusItem.isVisible = true
            statusItem.menu = nil
            button.image = NSImage(systemSymbolName: RecordingStatus.paused ? "pause.circle" : "stop.circle", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
            button.imagePosition = .imageLeading
            button.title = Defaults[Prefs.recTimeInMenuBar] ? " " + RecordingStatus.timeString : ""
            button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            button.target = self
            button.action = #selector(stopRecording)
            button.toolTip = "Stop recording"
        } else {
            button.image = MenuBarIcon.make()
            button.title = ""
            button.action = nil
            button.toolTip = nil
            statusItem.menu = menu
            updateVisibility()
        }
    }

    @objc private func stopRecording() { RecordingController.shared.toggle() }

    private func updateVisibility() {
        let visible = Defaults[Prefs.showMenuBarIcon]
        if statusItem.isVisible != visible { statusItem.isVisible = visible }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(.allInOne, symbol: "1.circle")
        add(.captureArea, symbol: "viewfinder")
        add(.capturePreviousArea, symbol: "arrow.clockwise")
        add(.captureFullscreen, symbol: "display")
        add(.captureWindow, symbol: "macwindow")
        add(.scrollingCapture, symbol: "arrow.down")
        add(.selfTimer, symbol: "timer")
        add(.captureText, title: "Capture Text (OCR)", symbol: "textformat")
        add(.recordScreen, title: "Record Screen", symbol: "video")
        menu.addItem(.separator())
        add(.toggleDesktopIcons, title: DesktopIconsHider.shared.isHidingIcons ? "Show Desktop Icons" : "Hide Desktop Icons",
            symbol: DesktopIconsHider.shared.isHidingIcons ? "eye" : "eye.slash")
        menu.addItem(.separator())
        add(.annotateFile, title: "Open…", symbol: "pencil")
        add(.pinImage, title: "Pin to the Screen…", symbol: "pin")
        menu.addItem(.separator())
        add(.openHistory, title: "Capture History…", symbol: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        menu.addItem(.separator())
        menu.addItem(item(title: "About Glint…", key: "", action: #selector(openAbout)))
        menu.addItem(item(title: "Check for Updates…", key: "", action: #selector(checkForUpdates)))
        menu.addItem(item(title: "Settings…", key: ",", action: #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit", key: "", action: #selector(quit)))
    }

    private func add(_ action: AppAction, title: String? = nil, symbol: String, image: NSImage? = nil) {
        let item = NSMenuItem(title: title ?? action.title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.image = image ?? Self.menuIcon(symbol)
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
        item.toolTip = Self.hints[action]
        if let combo = ShortcutManager.shared.shortcut(for: action) {
            item.keyEquivalent = combo.menuKeyEquivalent
            item.keyEquivalentModifierMask = combo.modifiers
        }
        menu.addItem(item)
    }

    private func item(title: String, key: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .hidden }
        return item
    }

    /// Symbol in a 22×24pt frame: the taller image makes rows ~30pt tall, with larger icons.
    private static func menuIcon(_ symbol: String) -> NSImage? {
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) else { return nil }
        let size = NSSize(width: 22, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            let g = glyph.size
            glyph.draw(in: NSRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2, width: g.width, height: g.height))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let hints: [AppAction: String] = [
        .allInOne: "Choose the capture type and area in one place.",
        .captureArea: "Drag to capture part of the screen. Press Space to pick a window instead.",
        .capturePreviousArea: "Capture the same area as your last area screenshot.",
        .captureFullscreen: "Capture the entire screen under the pointer.",
        .captureWindow: "Click a window to capture it with its shadow on your wallpaper.",
        .scrollingCapture: "Capture content taller than the screen by scrolling.",
        .selfTimer: "Select an area, then capture it after a countdown.",
        .captureText: "Select an area and copy the text in it.",
        .recordScreen: "Record a video or GIF of your screen.",
        .toggleDesktopIcons: "Hide or show desktop icons and widgets.",
        .annotateFile: "Open an image in the Annotate editor.",
        .pinImage: "Keep an image floating above all windows.",
        .openHistory: "Browse and restore recent captures.",
    ]

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = AppAction(rawValue: raw) else { return }
        // Let the menu finish closing before an overlay grabs the screen.
        DispatchQueue.main.async { AppRouter.perform(action) }
    }

    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func openAbout() { SettingsWindowController.shared.show(pane: .about) }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Template glyph for the menu bar: a dashed selection frame with a crosshair, echoing the app icon.
enum MenuBarIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 3, width: 13, height: 11), xRadius: 2, yRadius: 2)
            frame.lineWidth = 1.5
            frame.setLineDash([2.6, 1.7], count: 2, phase: 0)
            frame.stroke()
            let plus = NSBezierPath()
            plus.lineWidth = 1.6
            plus.lineCapStyle = .round
            plus.move(to: NSPoint(x: 14.5, y: 11.5)); plus.line(to: NSPoint(x: 14.5, y: 17))
            plus.move(to: NSPoint(x: 11.75, y: 14.25)); plus.line(to: NSPoint(x: 17.25, y: 14.25))
            plus.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
