import AppKit
import SwiftUI

/// Stack of floating capture thumbnails in the screen corner.
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private final class Entry {
        let item: CaptureItem
        let panel: QuickAccessPanel
        var timer: Timer?
        var hover = HoverState()
        /// The screenshot editor this card is open in (recordings are found by their file).
        weak var editor: AnnotateWindowController?
        init(item: CaptureItem, panel: QuickAccessPanel) { self.item = item; self.panel = panel }
    }

    private var entries: [Entry] = []  // oldest first; the newest sits at the bottom
    private var isHidden = false
    /// Swiped down out of view, with only the restore tab peeking up from the bottom edge.
    private var isCollapsed = false
    private var restoreTab: QuickAccessTabPanel?
    /// The restore tab fades out a second after it appears and comes back while the pointer is over its place.
    private var restoreTabVisible = true
    private var restoreTabHideAt: Date?
    /// The bar above the top card that tucks the stack away; it shows while the pointer is over the stack.
    private var hideBar: QuickAccessTabPanel?
    private var hideBarVisible = false
    private var hideBarHideAt: Date?
    private var pointerTimer: Timer?
    private let tabHeight: CGFloat = 30
    private let hideBarHeight: CGFloat = 30
    private let hideBarGap: CGFloat = 8
    /// Where the top card ends up after the last layout (not where it is mid-animation): the hide bar sits above it.
    private var stackTop: CGRect?
    private var stackBottom: CGFloat?
    private var observers: [Any] = []

    // 210×150pt cards, 40pt from the side, 100pt from the bottom, 12pt apart.
    private static let baseSize = CGSize(width: 210, height: 150)
    private static let sizeSteps: [CGFloat] = [0.7, 0.85, 1.0, 1.2, 1.4]
    private let sideMargin: CGFloat = 40
    private let bottomMargin: CGFloat = 100
    private let spacing: CGFloat = 12

    private init() {
        let center = NotificationCenter.default
        // An editor coming forward or closing: Quick Access moves behind it, and the auto-close timers wait while
        // any editor is open.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                if let window = note.object as? NSWindow, !Self.isEditor(window) { return }
                // A capture is over once Glint leaves the front or an editor is used again.
                if note.name == NSApplication.didResignActiveNotification || note.name == NSWindow.didBecomeKeyNotification {
                    MainActor.assumeIsolated { self?.captureFront = nil }
                }
                let closing = note.name == NSWindow.willCloseNotification
                // After the editor's own close handling, so `isEditorOpen` is up to date.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.updateLevels()
                        if closing { self?.restartTimers() }
                    }
                }
            })
        }
    }

    func show(_ item: CaptureItem) { _ = add(item) }

    /// Shows the capture and opens it in its editor right away (the "Open Annotate tool" after-capture action).
    func showEditing(_ item: CaptureItem) { annotate(add(item)) }

    private func add(_ item: CaptureItem) -> Entry {
        let panel = QuickAccessPanel(size: cardSize)
        let entry = Entry(item: item, panel: panel)
        let hover = entry.hover
        let card = QuickAccessCard(item: item, actions: QuickAccessCard.Actions(
            copy: { [weak self] in self?.copy(entry) },
            save: { [weak self] in self?.save(entry) },
            close: { [weak self] in self?.closeRequested(entry) },
            annotate: { [weak self] in self?.annotate(entry) },
            pin: { [weak self] in item.isRecording ? QuickLook.show(item.fileURL) : self?.pin(entry) },
            share: { [weak panel] in panel.map { QuickAccessManager.share(item, from: $0) } },
            hoverChanged: { _ in }
        ), hover: hover)
        let host = NSHostingView(rootView: card)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: cardSize)
        host.autoresizingMask = [.width, .height]
        let container = HoverTrackingView(frame: host.frame)
        container.addSubview(host)
        container.onHoverChanged = { [weak self] hovering in
            hover.isHovering = hovering
            self?.hoverChanged(entry, hovering: hovering)
        }
        panel.contentView = container
        panel.dragFileURL = item.fileURL
        panel.dragImage = item.nsImage
        panel.onDragEnded = { [weak self] dropped in self?.dragEnded(entry, dropped: dropped) }
        panel.onDoubleClick = { [weak self] in self?.annotate(entry) }
        panel.onClick = { [weak self] in self?.clicked(entry) }
        panel.dismissTowardRight = Defaults[Prefs.quickAccessPosition] == .right
        panel.onTuck = { [weak self] in self?.collapse() }
        panel.onDismiss = { [weak self] in self?.dismiss(entry) }
        panel.onSnapBack = { [weak self] in self?.layout(appearing: nil) }

        if isCollapsed { expand() }
        entries.append(entry)
        isHidden = false
        layout(appearing: entry)
        updateLevels()
        // Something new arrived: every card's auto-close starts over.
        restartTimers()
        startPointerTracking()
        return entry
    }

    func closeAll() { entries.forEach { close($0) } }

    func isShowing(_ file: URL) -> Bool { entries.contains { $0.item.fileURL == file } }

    #if DEBUG
    func debugShowHover() { entries.forEach { $0.hover.isHovering = true } }
    #endif

    /// The capture's file is going away.
    func close(file: URL) { entries.filter { $0.item.fileURL == file }.forEach { close($0) } }

    func saveAll() {
        entries.forEach { FileSaver.saveToExportLocation($0.item) }
        closeAll()
    }

    // MARK: Swipe away / restore

    /// Slides every card below the screen edge and shows the restore tab (swipe down, drag down or the hide bar).
    func collapse() {
        guard !isCollapsed, !entries.isEmpty, let screen = targetScreen else { return }
        isCollapsed = true
        hideHideBar(animated: false)
        for entry in entries {
            entry.timer?.invalidate()
            let panel = entry.panel
            var target = panel.frame
            target.origin.y = screen.frame.minY - target.height - 20
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                if self?.isCollapsed == true { panel.orderOut(nil) }
            })
        }
        showRestoreTab(on: screen)
    }

    /// Brings the cards back up with a slight overshoot.
    func expand() {
        guard isCollapsed, let screen = targetScreen else { return }
        isCollapsed = false
        hideRestoreTab()
        for entry in entries {
            var start = entry.panel.frame
            start.origin.y = screen.frame.minY - start.height - 20
            entry.panel.setFrame(start, display: false)
            if !isHidden { entry.panel.orderFrontRegardless() }
        }
        layout(appearing: nil, springy: true)
        updateLevels()
        restartTimers()
    }

    private func showRestoreTab(on screen: NSScreen) {
        guard !entries.isEmpty else { return }
        let size = CGSize(width: cardSize.width, height: tabHeight)
        let x = Defaults[Prefs.quickAccessPosition] == .left ? screen.visibleFrame.minX + sideMargin
                                                             : screen.visibleFrame.maxX - sideMargin - size.width
        let tab = QuickAccessTabPanel(size: size)
        tab.setContent(QuickAccessRestoreTab(state: tab.state))
        tab.onActivate = { [weak self] in self?.expand() }
        tab.activateDirection = .up
        tab.setFrame(CGRect(x: x, y: screen.frame.minY - size.height, width: size.width, height: size.height), display: false)
        tab.alphaValue = 1
        tab.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            tab.animator().setFrame(CGRect(x: x, y: screen.frame.minY, width: size.width, height: size.height), display: true)
        }
        restoreTab = tab
        restoreTabVisible = true
        restoreTabHideAt = Date().addingTimeInterval(1.3)  // the slide-in, then one second
        updateLevels()
        startPointerTracking()
    }

    private func hideRestoreTab() {
        guard let tab = restoreTab else { return }
        restoreTab = nil
        restoreTabHideAt = nil
        var target = tab.frame
        target.origin.y -= target.height
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            tab.animator().setFrame(target, display: true)
        }, completionHandler: { tab.orderOut(nil) })
    }

    func toggleVisibility() {
        isHidden.toggle()
        entries.forEach { isHidden ? $0.panel.orderOut(nil) : $0.panel.orderFrontRegardless() }
        if isHidden { hideHideBar(animated: false) } else { updateLevels() }
    }

    // MARK: Hide bar and pointer tracking

    private func makeHideBar() -> QuickAccessTabPanel {
        let size = CGSize(width: cardSize.width, height: hideBarHeight)
        let bar = QuickAccessTabPanel(size: size)
        bar.setContent(QuickAccessHideBar(state: bar.state))
        bar.onActivate = { [weak self] in self?.collapse() }
        bar.activateDirection = .down
        bar.alphaValue = 0
        return bar
    }

    /// Where the hide bar sits: centered above the top card.
    private func hideBarFrame() -> CGRect? {
        guard !entries.isEmpty, let top = stackTop else { return nil }
        return CGRect(x: top.minX, y: top.maxY + hideBarGap, width: top.width, height: hideBarHeight)
    }

    private func showHideBar() {
        guard !isCollapsed, !isHidden, let frame = hideBarFrame() else { return }
        let bar = hideBar ?? makeHideBar()
        hideBar = bar
        hideBarHideAt = nil
        guard !hideBarVisible else { return }
        hideBarVisible = true
        bar.setFrame(frame, display: false)
        bar.ignoresMouseEvents = false
        bar.orderFrontRegardless()
        updateLevels()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            bar.animator().alphaValue = 1
        }
    }

    private func hideHideBar(animated: Bool = true) {
        hideBarHideAt = nil
        guard hideBarVisible, let bar = hideBar else { return }
        hideBarVisible = false
        bar.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = animated ? 0.25 : 0
            bar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.hideBarVisible == false { bar.orderOut(nil) }
        })
    }

    private func setRestoreTab(visible: Bool) {
        guard let tab = restoreTab, restoreTabVisible != visible else { return }
        restoreTabVisible = visible
        tab.ignoresMouseEvents = !visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.15 : 0.35
            tab.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Watches the pointer (tracking areas don't fire for faded-out or not-yet-shown panels): it reveals the hide bar
    /// over the stack, and the faded restore tab over its place at the bottom edge.
    private func startPointerTracking() {
        guard pointerTimer == nil else { return }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
    }

    private func trackPointer() {
        guard !entries.isEmpty else {
            pointerTimer?.invalidate()
            pointerTimer = nil
            hideHideBar(animated: false)
            return
        }
        let mouse = NSEvent.mouseLocation
        let now = Date()
        // Backs up the bars' tracking areas, which miss a pointer that's already inside when a bar appears.
        for bar in [hideBar, restoreTab].compactMap({ $0 }) where bar.isVisible {
            let inside = bar.frame.contains(mouse)
            if bar.state.hovering != inside { bar.state.hovering = inside }
        }
        if isCollapsed, let tab = restoreTab {
            // The tab's place, a little taller, down to the screen edge.
            let zone = tab.frame.insetBy(dx: -8, dy: -12)
            if zone.contains(mouse) {
                restoreTabHideAt = nil
                setRestoreTab(visible: true)
            } else if restoreTabVisible {
                if restoreTabHideAt == nil { restoreTabHideAt = now.addingTimeInterval(1) }
                if let at = restoreTabHideAt, now >= at { restoreTabHideAt = nil; setRestoreTab(visible: false) }
            }
            return
        }
        guard !isHidden, let barFrame = hideBarFrame() else { return }
        // The stack where it's headed (the cards may still be sliding), plus the bar above it.
        let bottom = stackBottom ?? barFrame.minY
        let stack = barFrame.union(CGRect(x: barFrame.minX, y: bottom, width: barFrame.width, height: 1)).insetBy(dx: -6, dy: -6)
        if stack.contains(mouse) {
            showHideBar()
        } else if hideBarVisible {
            if hideBarHideAt == nil { hideBarHideAt = now.addingTimeInterval(0.6) }
            if let at = hideBarHideAt, now >= at { hideHideBar() }
        }
    }

    // MARK: Editors

    private static func isEditor(_ window: NSWindow) -> Bool {
        window.windowController is AnnotateWindowController || window.windowController is VideoEditorWindowController
            || window.windowController is GIFTrimmer
    }

    private var isEditorOpen: Bool {
        AnnotateWindowController.hasOpenEditors || VideoEditorWindowController.hasOpenEditors || GIFTrimmer.hasOpenEditors
    }

    /// Layering while Glint is in front with an editor open: the editors on top, then Quick Access, then other apps'
    /// windows. The cards stay floating panels throughout (as normal windows they'd show up in Mission Control).
    /// This is the only place that sets the editors' levels (Always on top included), so nothing else can undo it.
    func updateLevels() {
        let editors = NSApp.windows.filter { $0.isVisible && Self.isEditor($0) }
        let raise = NSApp.isActive && !editors.isEmpty && captureFront == nil
        let above = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        for window in editors {
            // Above the normal level, macOS leaves windows out of Mission Control unless they say they take part.
            window.collectionBehavior.insert(.managed)
            let base: NSWindow.Level = window.windowController is AnnotateWindowController && Defaults[Prefs.annotateAlwaysOnTop] ? .floating : .normal
            window.level = raise ? above : base
        }
        // The color panel (custom colors) must stay above the raised editors.
        if raise, NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.level = NSWindow.Level(rawValue: above.rawValue + 1) }
        for panel in entries.map(\.panel) + [hideBar, restoreTab].compactMap({ $0 }) { panel.level = .floating }
        // Activating Glint brought its editors forward: back behind the window that was in front.
        if let front = captureFront {
            for window in NSApp.orderedWindows.reversed() where editors.contains(window) { window.order(.below, relativeTo: front.window) }
        }
    }

    // MARK: Captures

    /// While a capture's overlay has Glint in front, the editors stay where they were: behind the app the user is
    /// capturing (activating Glint would otherwise bring them forward and raise them over everything).
    private var captureFront: (app: NSRunningApplication, window: Int)?

    /// Activates Glint for a capture overlay (it needs the keyboard) without bringing the editors forward.
    func activateForCapture() {
        captureFront = nil
        if let app = NSWorkspace.shared.frontmostApplication, app != .current,
           NSApp.windows.contains(where: { $0.isVisible && Self.isEditor($0) }),
           let window = Self.frontWindow(of: app.processIdentifier) {
            captureFront = (app, window)
        }
        NSApp.activate()
        updateLevels()
    }

    /// After a screenshot: the keyboard goes back to the app that was in front, and the editors stay behind it.
    func captureEnded() {
        guard let front = captureFront else { return }
        if NSApp.isActive { front.app.activate() } else { captureFront = nil; updateLevels() }
    }

    /// The frontmost normal window of an app.
    private static func frontWindow(of pid: pid_t) -> Int? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }?[kCGWindowNumber as String] as? Int
    }

    /// Clicking a card that's open in an editor brings that editor forward.
    private func clicked(_ entry: Entry) {
        guard entry.hover.isEditing else { return }
        DispatchQueue.main.async {
            if entry.item.isRecording {
                VideoEditorWindowController.open(url: entry.item.fileURL)  // fronts the open editor
            } else if let window = entry.editor?.window {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: Actions

    /// Opens the capture in its editor (Annotate or the video editor). The card stays in the stack, see-through and
    /// without buttons, until the editor closes; then it's replaced by the edited result (or simply comes back).
    private func annotate(_ entry: Entry) {
        guard !entry.hover.isEditing else { clicked(entry); return }
        entry.hover.isEditing = true
        entry.timer?.invalidate()
        entry.timer = nil
        let item = entry.item
        // Leave the non-activating panel's event handling before activating the app for the editor.
        DispatchQueue.main.async { [weak self] in
            if item.isRecording {
                let modified = Self.modificationDate(item.fileURL)
                VideoEditorWindowController.open(url: item.fileURL, onClose: { [weak self] in
                    guard let self else { return }
                    if Self.modificationDate(item.fileURL) != modified, let fresh = CaptureItem.loadRecording(item.fileURL, date: item.date) {
                        self.replace(entry, with: fresh)
                    } else {
                        self.editingEnded(entry)
                    }
                })
            } else {
                let editor = AnnotateWindowController.open(item: item)
                entry.editor = editor
                editor.onFinish = { [weak self] result in
                    if result === item { self?.editingEnded(entry) } else { self?.replace(entry, with: result) }
                }
            }
            self?.updateLevels()
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func editingEnded(_ entry: Entry) {
        entry.hover.isEditing = false
        entry.editor = nil
        restartTimers()
    }

    /// The editor produced a new version: it takes the card's place in the stack.
    private func replace(_ entry: Entry, with item: CaptureItem) {
        guard entries.contains(where: { $0 === entry }) else { show(item); return }
        close(entry)
        show(item)
    }

    private func pin(_ entry: Entry) {
        PinManager.shared.pin(entry.item)
        close(entry)
    }

    private func copy(_ entry: Entry) {
        Clipboard.copy(entry.item)
        close(entry)
    }

    private func save(_ entry: Entry) {
        let askForLocation = Defaults[Prefs.quickAccessSaveBehavior] == .ask || NSEvent.modifierFlags.contains(.option)
        let saved = askForLocation ? FileSaver.saveWithPanel(entry.item) : FileSaver.saveToExportLocation(entry.item)
        if saved != nil { close(entry) }
    }

    private static func share(_ item: CaptureItem, from panel: NSPanel) {
        guard let view = panel.contentView else { return }
        let picker = NSSharingServicePicker(items: [item.fileURL])
        picker.show(relativeTo: CGRect(x: view.bounds.maxX - 20, y: 4, width: 16, height: 16), of: view, preferredEdge: .maxX)
    }

    private func dragEnded(_ entry: Entry, dropped: Bool) {
        guard dropped, Defaults[Prefs.quickAccessCloseAfterDragging], !NSEvent.modifierFlags.contains(.option) else { return }
        close(entry)
    }

    private func hoverChanged(_ entry: Entry, hovering: Bool) {
        // Pause auto-close while the pointer is over the card.
        if hovering { entry.timer?.invalidate(); entry.timer = nil } else { scheduleAutoClose(entry) }
    }

    /// Dragged or swiped toward the screen edge: like the close button. If a recording's close is cancelled, the card
    /// slides back.
    private func dismiss(_ entry: Entry) {
        closeRequested(entry)
        if entries.contains(where: { $0 === entry }) {
            entry.panel.alphaValue = 1
            layout(appearing: nil)
        }
    }

    /// The close button: recordings ask first ("You may lose the file if it hasn't been saved.").
    private func closeRequested(_ entry: Entry) {
        guard entry.item.isRecording, Defaults[Prefs.recConfirmClose] else { close(entry); return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to close this recording?"
        alert.informativeText = "You may lose the file if it hasn't been saved."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask for confirmation"
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { Defaults[Prefs.recConfirmClose] = false }
        if response == .alertFirstButtonReturn { close(entry) }
    }

    private func close(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0 === entry }) else { return }
        entry.timer?.invalidate()
        entries.remove(at: index)
        if entries.isEmpty { hideHideBar(); stackTop = nil; stackBottom = nil }
        if isCollapsed {
            entry.panel.orderOut(nil)
            if entries.isEmpty { isCollapsed = false; hideRestoreTab() }
            return
        }
        let panel = entry.panel
        var target = panel.frame
        target.origin.x += Defaults[Prefs.quickAccessPosition] == .left ? -(target.width + sideMargin) : target.width + sideMargin
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
        layout(appearing: nil)
    }

    /// Starts every card's auto-close over (something was added, an editor closed, the stack came back).
    private func restartTimers() { entries.forEach(scheduleAutoClose) }

    /// Auto-close only runs while Glint is idle: never while an editor is open, the stack is tucked away or the
    /// pointer is over the card.
    private func scheduleAutoClose(_ entry: Entry) {
        entry.timer?.invalidate()
        entry.timer = nil
        guard !entry.hover.isEditing, !entry.hover.isHovering, !isCollapsed, !isEditorOpen else { return }
        guard Defaults[Prefs.quickAccessAutoClose] else { return }
        let interval = TimeInterval(Defaults[Prefs.quickAccessAutoCloseInterval])
        entry.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self, weak entry] _ in
            MainActor.assumeIsolated {
                guard let self, let entry, !self.isEditorOpen else { return }
                if Defaults[Prefs.quickAccessAutoCloseAction] == .saveAndClose { FileSaver.saveToExportLocation(entry.item) }
                self.close(entry)
            }
        }
    }

    // MARK: Layout

    private var cardSize: CGSize {
        let step = min(max(Int(Defaults[Prefs.quickAccessSize].rounded()), 0), Self.sizeSteps.count - 1)
        let k = Self.sizeSteps[step]
        return CGSize(width: (Self.baseSize.width * k).rounded(), height: (Self.baseSize.height * k).rounded())
    }

    private var targetScreen: NSScreen? {
        Defaults[Prefs.quickAccessMoveToActiveScreen] ? NSScreen.withMouse : NSScreen.main
    }

    private func layout(appearing: Entry?, springy: Bool = false) {
        guard !isCollapsed, let screen = targetScreen else { return }
        let visible = screen.visibleFrame
        let side = Defaults[Prefs.quickAccessPosition]
        // With the Dock hidden keep 100pt clear at the bottom; with it visible, sit just above it.
        let dockAtBottom = visible.minY - screen.frame.minY > 1
        var y = dockAtBottom ? visible.minY + sideMargin : screen.frame.minY + bottomMargin
        stackBottom = y
        var topFrame: CGRect?
        for entry in entries.reversed() {
            let size = entry.panel.frame.size
            let x = side == .left ? visible.minX + sideMargin : visible.maxX - sideMargin - size.width
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            topFrame = frame
            y += size.height + spacing
            if entry === appearing {
                var start = frame
                start.origin.x = side == .left ? visible.minX - size.width : visible.maxX
                entry.panel.setFrame(start, display: false)
                entry.panel.alphaValue = 1
                if !isHidden { entry.panel.orderFrontRegardless() }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    entry.panel.animator().setFrame(frame, display: true)
                }
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = springy ? 0.42 : 0.25
                    // Overshooting curve for the restore, with a little bounce.
                    ctx.timingFunction = springy ? CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.55, 1) : nil
                    entry.panel.animator().setFrame(frame, display: true)
                }
            }
        }
        stackTop = topFrame
        // The hide bar follows the top card (or waits, hidden, where it will show next).
        if let bar = hideBar, let target = hideBarFrame() {
            if hideBarVisible {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = springy ? 0.42 : 0.25
                    ctx.timingFunction = springy ? CAMediaTimingFunction(controlPoints: 0.3, 1.35, 0.55, 1) : nil
                    bar.animator().setFrame(target, display: true)
                }
            } else {
                bar.setFrame(target, display: false)
            }
        }
    }
}

/// Floating panel for one card. Handles drag & drop at the window level so a drag can start anywhere on the card.
/// A drag that starts downward tucks the stack away, one toward the screen edge closes the card (the card follows the
/// pointer); any other direction drags the file. Two-finger swipes do the same: down tucks away, toward the edge closes.
final class QuickAccessPanel: NSPanel, NSDraggingSource {
    var dragFileURL: URL?
    var dragImage: NSImage?
    var onDragEnded: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    /// A single click that didn't turn into a drag.
    var onClick: (() -> Void)?
    /// Pulled or swiped down: tuck the stack away.
    var onTuck: (() -> Void)?
    /// Pulled or swiped toward the screen edge: close the card.
    var onDismiss: (() -> Void)?
    /// A pull that wasn't far enough: back into place.
    var onSnapBack: (() -> Void)?
    /// Quick Access on the right: closing goes right instead of left.
    var dismissTowardRight = false
    private var mouseDownEvent: NSEvent?
    private var mouseDownScreen: NSPoint = .zero
    private enum Pull { case tuck, dismiss }
    private var pull: Pull?
    private var pullStart: CGRect = .zero
    private let swipe = SwipeDetector()
    private var edgeDirection: SwipeDetector.Direction { dismissTowardRight ? .right : .left }

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    private func screenPoint(_ event: NSEvent) -> NSPoint { convertPoint(toScreen: event.locationInWindow) }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownEvent = event
            mouseDownScreen = screenPoint(event)
            pull = nil
            if event.clickCount == 2 { onDoubleClick?() }
        case .leftMouseDragged:
            if pull != nil { followPull(event); return }
            if mouseDownEvent != nil {
                let p = screenPoint(event)
                let dx = p.x - mouseDownScreen.x, dy = p.y - mouseDownScreen.y
                if hypot(dx, dy) > 4 {
                    mouseDownEvent = nil
                    let towardEdge = dismissTowardRight ? dx : -dx
                    if -dy > abs(dx) {
                        pull = .tuck
                    } else if towardEdge > abs(dy) {
                        pull = .dismiss
                    } else {
                        beginFileDrag(with: event)
                        return
                    }
                    pullStart = frame
                    followPull(event)
                    return
                }
            }
        case .leftMouseUp:
            if let pull {
                endPull(pull, event)
                self.pull = nil
                mouseDownEvent = nil
                return
            }
            if mouseDownEvent != nil, event.clickCount == 1 { onClick?() }
            mouseDownEvent = nil
        case .scrollWheel:
            switch swipe.feed(event) {
            case .down?: onTuck?()
            case let direction? where direction == edgeDirection: onDismiss?()
            default: break
            }
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// The card follows the pointer on the pull's axis; pulling the other way only gives a little.
    private func followPull(_ event: NSEvent) {
        let p = screenPoint(event)
        var origin = pullStart.origin
        switch pull {
        case .tuck?:
            let dy = p.y - mouseDownScreen.y
            origin.y += dy < 0 ? dy : dy * 0.15
        case .dismiss?:
            let dx = p.x - mouseDownScreen.x
            let towardEdge = dismissTowardRight ? dx : -dx
            let moved = towardEdge > 0 ? towardEdge : towardEdge * 0.15
            origin.x += dismissTowardRight ? moved : -moved
            alphaValue = 1 - min(max(moved, 0) / pullStart.width, 1) * 0.6
        case nil:
            break
        }
        setFrameOrigin(origin)
    }

    private func endPull(_ pull: Pull, _ event: NSEvent) {
        let p = screenPoint(event)
        switch pull {
        case .tuck:
            if mouseDownScreen.y - p.y > 30 { onTuck?() } else { onSnapBack?() }
        case .dismiss:
            let towardEdge = dismissTowardRight ? p.x - mouseDownScreen.x : mouseDownScreen.x - p.x
            if towardEdge > 50 {
                onDismiss?()
            } else {
                alphaValue = 1
                onSnapBack?()
            }
        }
    }

    private func beginFileDrag(with event: NSEvent) {
        guard let url = dragFileURL, let view = contentView else { return }
        let pbItem = NSPasteboardItem()
        pbItem.setString(url.absoluteString, forType: .fileURL)
        // Older Cocoa and Electron apps still look for the legacy filenames type.
        pbItem.setPropertyList([url.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        dragItem.setDraggingFrame(view.bounds, contents: dragImage)
        let session = view.beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic, .link]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(!operation.isEmpty)
    }
}

/// A small bar panel: the restore tab at the bottom edge while cards are swiped away (click, swipe up or drag up to
/// bring them back), and the hide bar above the stack (click, swipe down or drag down to tuck them away).
final class QuickAccessTabPanel: NSPanel {
    var onActivate: (() -> Void)?
    /// Hover and press feedback for the bar's look.
    let state = BarState()
    /// The swipe or drag direction that activates it.
    var activateDirection: SwipeDetector.Direction = .up
    private let swipe = SwipeDetector()
    private var mouseDown: NSPoint?
    private var dragged = false

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        animationBehavior = .none
    }

    /// Puts the bar's SwiftUI view in a hover-tracking container (SwiftUI's onHover needs Glint to be active).
    func setContent<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        let container = HoverTrackingView(frame: host.frame)
        container.addSubview(host)
        container.onHoverChanged = { [state] in state.hovering = $0; if !$0 { state.pressed = false } }
        contentView = container
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDown = event.locationInWindow
            dragged = false
            state.pressed = true
        case .leftMouseDragged:
            if let start = mouseDown, !dragged {
                let dy = event.locationInWindow.y - start.y  // up is positive
                if (activateDirection == .up && dy > 8) || (activateDirection == .down && dy < -8) {
                    dragged = true
                    onActivate?()
                }
            }
        case .leftMouseUp:
            state.pressed = false
            if !dragged { onActivate?() }
            mouseDown = nil
        case .scrollWheel: if swipe.feed(event) == activateDirection { onActivate?() }
        default: break
        }
        super.sendEvent(event)
    }
}

/// Turns trackpad swipes (and mouse-wheel spins) into a single direction, in finger direction.
final class SwipeDetector {
    enum Direction { case up, down, left, right }
    private var travelX: CGFloat = 0
    private var travelY: CGFloat = 0
    private var fired = false
    private var lastEvent: TimeInterval = 0
    private let threshold: CGFloat = 36

    func feed(_ event: NSEvent) -> Direction? {
        guard event.momentumPhase.isEmpty else { return nil }  // ignore inertia after the fingers lift
        if event.phase.contains(.began) || (event.phase.isEmpty && event.timestamp - lastEvent > 0.4) {
            travelX = 0
            travelY = 0
            fired = false
        }
        lastEvent = event.timestamp
        // Positive = fingers (or wheel) moving down / right, independent of the "natural scrolling" setting.
        let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        travelY += event.scrollingDeltaY * k * sign
        travelX += event.scrollingDeltaX * k * sign
        guard !fired, max(abs(travelX), abs(travelY)) > threshold else { return nil }
        fired = true
        if abs(travelY) >= abs(travelX) { return travelY > 0 ? .down : .up }
        return travelX > 0 ? .right : .left
    }
}
