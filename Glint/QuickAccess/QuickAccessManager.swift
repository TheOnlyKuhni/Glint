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
        init(item: CaptureItem, panel: QuickAccessPanel) { self.item = item; self.panel = panel }
    }

    private var entries: [Entry] = []  // oldest first; the newest sits at the bottom
    private var isHidden = false
    /// Swiped down out of view, with only the restore tab peeking up from the bottom edge.
    private var isCollapsed = false
    private var restoreTab: QuickAccessTabPanel?
    private let tabHeight: CGFloat = 30

    // 210×150pt cards, 40pt from the side, 100pt from the bottom, 12pt apart.
    private static let baseSize = CGSize(width: 210, height: 150)
    private static let sizeSteps: [CGFloat] = [0.7, 0.85, 1.0, 1.2, 1.4]
    private let sideMargin: CGFloat = 40
    private let bottomMargin: CGFloat = 100
    private let spacing: CGFloat = 12

    func show(_ item: CaptureItem) {
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
        panel.onSwipeDown = { [weak self] in self?.collapse() }

        if isCollapsed { expand() }
        entries.append(entry)
        isHidden = false
        layout(appearing: entry)
        scheduleAutoClose(entry)
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

    /// Slides every card below the screen edge and shows the restore tab (swipe down).
    func collapse() {
        guard !isCollapsed, !entries.isEmpty, let screen = targetScreen else { return }
        isCollapsed = true
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
            scheduleAutoClose(entry)
        }
        layout(appearing: nil, springy: true)
    }

    private func showRestoreTab(on screen: NSScreen) {
        guard let newest = entries.last else { return }
        let size = CGSize(width: cardSize.width, height: tabHeight)
        let x = Defaults[Prefs.quickAccessPosition] == .left ? screen.visibleFrame.minX + sideMargin
                                                             : screen.visibleFrame.maxX - sideMargin - size.width
        let tab = QuickAccessTabPanel(size: size)
        let host = NSHostingView(rootView: QuickAccessRestoreTab(item: newest.item, cardSize: cardSize, visibleHeight: tabHeight))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        tab.contentView = host
        tab.onActivate = { [weak self] in self?.expand() }
        tab.setFrame(CGRect(x: x, y: screen.frame.minY - size.height, width: size.width, height: size.height), display: false)
        tab.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            tab.animator().setFrame(CGRect(x: x, y: screen.frame.minY, width: size.width, height: size.height), display: true)
        }
        restoreTab = tab
    }

    private func hideRestoreTab() {
        guard let tab = restoreTab else { return }
        restoreTab = nil
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
    }

    // MARK: Actions

    /// Opens the capture in its editor (Annotate or the video editor). The card stays in the stack, see-through and
    /// without buttons, until the editor closes; then it's replaced by the edited result (or simply comes back).
    private func annotate(_ entry: Entry) {
        guard !entry.hover.isEditing else { return }
        entry.hover.isEditing = true
        entry.timer?.invalidate()
        entry.timer = nil
        let item = entry.item
        // Leave the non-activating panel's event handling before activating the app for the editor.
        DispatchQueue.main.async { [weak self] in
            if item.isRecording {
                let modified = Self.modificationDate(item.fileURL)
                VideoEditorWindowController.open(url: item.fileURL) { [weak self] in
                    guard let self else { return }
                    if Self.modificationDate(item.fileURL) != modified, let fresh = CaptureItem.loadRecording(item.fileURL, date: item.date) {
                        self.replace(entry, with: fresh)
                    } else {
                        self.editingEnded(entry)
                    }
                }
            } else {
                let editor = AnnotateWindowController.open(item: item)
                editor.onFinish = { [weak self] result in
                    if result === item { self?.editingEnded(entry) } else { self?.replace(entry, with: result) }
                }
            }
        }
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func editingEnded(_ entry: Entry) {
        entry.hover.isEditing = false
        if !isCollapsed { scheduleAutoClose(entry) }
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
        if hovering { entry.timer?.invalidate(); entry.timer = nil } else if !isCollapsed { scheduleAutoClose(entry) }
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

    private func scheduleAutoClose(_ entry: Entry) {
        entry.timer?.invalidate()
        guard !entry.hover.isEditing else { return }
        guard Defaults[Prefs.quickAccessAutoClose] else { return }
        let interval = TimeInterval(Defaults[Prefs.quickAccessAutoCloseInterval])
        entry.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self, weak entry] _ in
            MainActor.assumeIsolated {
                guard let self, let entry else { return }
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
        for entry in entries.reversed() {
            let size = entry.panel.frame.size
            let x = side == .left ? visible.minX + sideMargin : visible.maxX - sideMargin - size.width
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
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
    }
}

/// Floating panel for one card. Handles drag & drop at the window level so a drag can start anywhere on the card.
final class QuickAccessPanel: NSPanel, NSDraggingSource {
    var dragFileURL: URL?
    var dragImage: NSImage?
    var onDragEnded: ((Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onSwipeDown: (() -> Void)?
    private var mouseDownEvent: NSEvent?
    private let swipe = SwipeDetector()

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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseDownEvent = event
            if event.clickCount == 2 { onDoubleClick?() }
        case .leftMouseDragged:
            if let down = mouseDownEvent,
               hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 4 {
                mouseDownEvent = nil
                beginFileDrag(with: event)
                return
            }
        case .leftMouseUp:
            mouseDownEvent = nil
        case .scrollWheel:
            if swipe.feed(event) == .down { onSwipeDown?() }
            return
        default:
            break
        }
        super.sendEvent(event)
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

/// The tab at the bottom edge while cards are swiped away. Click it (or swipe up on it) to bring them back.
final class QuickAccessTabPanel: NSPanel {
    var onActivate: (() -> Void)?
    private let swipe = SwipeDetector()

    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp: onActivate?()
        case .scrollWheel: if swipe.feed(event) == .up { onActivate?() }
        default: break
        }
        super.sendEvent(event)
    }
}

/// Turns trackpad swipes (and mouse-wheel spins) into a single up/down decision, in finger direction.
final class SwipeDetector {
    enum Direction { case up, down }
    private var travel: CGFloat = 0
    private var fired = false
    private var lastEvent: TimeInterval = 0
    private let threshold: CGFloat = 36

    func feed(_ event: NSEvent) -> Direction? {
        guard event.momentumPhase.isEmpty else { return nil }  // ignore inertia after the fingers lift
        if event.phase.contains(.began) || (event.phase.isEmpty && event.timestamp - lastEvent > 0.4) {
            travel = 0
            fired = false
        }
        lastEvent = event.timestamp
        // Positive = fingers (or wheel) moving down, independent of the "natural scrolling" setting.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        travel += event.isDirectionInvertedFromDevice ? delta : -delta
        guard !fired, abs(travel) > threshold else { return nil }
        fired = true
        return travel > 0 ? .down : .up
    }
}
