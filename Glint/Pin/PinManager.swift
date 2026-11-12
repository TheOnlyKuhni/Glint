import AppKit
import SwiftUI

/// Pinned screenshots ("Pin to the Screen"): floating images above every window.
final class PinManager {
    static let shared = PinManager()

    private var pins: [PinWindow] = []
    private var isHidden = false
    private var monitors: [Any] = []

    /// Pins a capture where it was taken (area captures), otherwise centered on the screen with the pointer.
    func pin(_ item: CaptureItem) {
        let pin = PinWindow(item: item)
        pin.onClose = { [weak self, weak pin] in pin.map { self?.remove($0) } }
        pins.append(pin)
        if isHidden { isHidden = false; pins.forEach { $0.orderFrontRegardless() } }
        pin.present()
        startMonitoring()
    }

    func pinLastScreenshot() {
        if let last = HistoryStore.shared.lastCapture { pin(last) } else { NSSound.beep() }
    }

    func pinFromPanel() {
        NSApp.bringToFront()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let item = CaptureItem.load(url) { pin(item) } else { NSSound.beep() }
        }
    }

    /// "Hide/Show Pinned Screenshots".
    func toggleAll() {
        guard !pins.isEmpty else { return }
        isHidden.toggle()
        pins.forEach { isHidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }

    func closeAll() { pins.forEach { $0.close() } }

    private func remove(_ pin: PinWindow) {
        pins.removeAll { $0 === pin }
        if pins.isEmpty { stopMonitoring() }
    }

    /// Hover is tracked from the pointer position: tracking areas don't fire for click-through (locked) pins,
    /// and SwiftUI hover doesn't work in non-activating panels.
    private func startMonitoring() {
        guard monitors.isEmpty else { return }
        let update: (NSEvent) -> Void = { [weak self] _ in self?.pointerMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: update) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { update($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Puts a pin behind all other pins (they share one window level).
    func sendToBack(_ pin: NSWindow) {
        let order = NSWindow.windowNumbers(options: []) ?? []
        let others = pins.filter { $0 !== pin && $0.isVisible }
        guard let last = others.max(by: { (order.firstIndex(of: NSNumber(value: $0.windowNumber)) ?? 0) < (order.firstIndex(of: NSNumber(value: $1.windowNumber)) ?? 0) })
        else { return }
        pin.order(.below, relativeTo: last.windowNumber)
    }

    private func pointerMoved() {
        let p = NSEvent.mouseLocation
        // Only the frontmost pin under the pointer counts as hovered. The window server's front-to-back order
        // (`orderedIndex` isn't kept up to date for non-activating panels).
        let order = NSWindow.windowNumbers(options: []) ?? []
        func rank(_ pin: NSWindow) -> Int { order.firstIndex(of: NSNumber(value: pin.windowNumber)) ?? Int.max }
        // Locked pins let the pointer through, so every locked pin under it fades (overlapping ones together);
        // an unlocked pin covers the ones behind it.
        var covered = false
        for pin in pins.sorted(by: { rank($0) < rank($1) }) {
            let inside = !covered && pin.isVisible && pin.frame.contains(p)
            if inside, !pin.isLocked { covered = true }
            pin.pointer(at: p, inside: inside)
        }
    }
}

final class PinModel: ObservableObject {
    @Published var hovering = false
    @Published var locked = false
    @Published var zoom: CGFloat = 1
    @Published var pressed: PinWindow.Control?
}

/// One pinned image: a borderless, non-activating panel at the pin window level, with rounded corners, a border and the
/// system shadow (each switchable). Drag to move, scroll or pinch to zoom around the center, right-click for options.
/// Locked pins can't be moved and let clicks through, except on their close and lock buttons; hovered, they fade.
final class PinWindow: NSPanel, NSDraggingSource {
    enum Control { case close, lock, handle, zoomLabel }

    let item: CaptureItem
    let model = PinModel()
    var onClose: (() -> Void)?
    private let imageLayer = CALayer()
    private var rounded = Defaults[Prefs.pinRoundedCorners]
    private var bordered = Defaults[Prefs.pinBorder]
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var downControl: Control?
    private var downEvent: NSEvent?

    private static let cornerRadius: CGFloat = 17
    private var baseSize: CGSize { item.pointSize }

    init(item: CaptureItem) {
        self.item = item
        super.init(contentRect: CGRect(origin: .zero, size: item.pointSize), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: 103)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = Defaults[Prefs.pinShadow]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none

        let content = PinContentView(frame: CGRect(origin: .zero, size: item.pointSize))
        content.wantsLayer = true
        content.owner = self
        imageLayer.contents = item.image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.masksToBounds = true
        imageLayer.frame = content.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        content.layer?.addSublayer(imageLayer)
        let controls = PassThroughHostingView(rootView: PinControls(model: model))
        controls.frame = content.bounds
        controls.autoresizingMask = [.width, .height]
        content.addSubview(controls)
        contentView = content
        applyStyle()
    }

    override var canBecomeKey: Bool { true }

    func present() {
        let screen = item.screenRect.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.withMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        if let rect = item.screenRect {
            setFrame(rect, display: true)
        } else {
            // Bigger than the screen: start zoomed out to fit. It is centered horizontally with its middle 6% of the
            // screen height above the screen's middle.
            let fit = min(1, visible.width * 0.9 / baseSize.width, visible.height * 0.9 / baseSize.height)
            model.zoom = fit
            let size = CGSize(width: (baseSize.width * fit).rounded(), height: (baseSize.height * fit).rounded())
            let full = screen?.frame ?? visible
            var origin = CGPoint(x: (full.midX - size.width / 2).rounded(), y: (full.minY + full.height * 0.56 - size.height / 2).rounded())
            origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
            setFrame(CGRect(origin: origin, size: size), display: true)
        }
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; animator().alphaValue = 1 }
    }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }

    // MARK: Style

    private func applyStyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.cornerRadius = rounded ? Self.cornerRadius : 0
        imageLayer.cornerCurve = .continuous
        imageLayer.borderWidth = bordered ? 0.5 : 0
        imageLayer.borderColor = NSColor(white: 0.5, alpha: 0.6).cgColor
        CATransaction.commit()
        invalidateShadow()
    }

    // MARK: Zoom

    func setZoom(_ zoom: CGFloat) {
        let z = min(max(zoom, 0.1), 8)
        let size = CGSize(width: max(baseSize.width * z, 24), height: max(baseSize.height * z, 24))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        model.zoom = z
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(CGRect(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded(),
                        width: size.width.rounded(), height: size.height.rounded()), display: true)
        CATransaction.commit()
        invalidateShadow()
    }

    // MARK: Pointer

    /// Rects of the hover controls, in the content view's (top-left) coordinates.
    func rect(of control: Control) -> CGRect {
        let b = contentView?.bounds ?? .zero
        switch control {
        case .close: return CGRect(x: 10, y: 10, width: 22, height: 22)
        case .lock: return CGRect(x: b.width - 32, y: 10, width: 22, height: 22)
        case .handle: return CGRect(x: (b.width - 52) / 2, y: b.height - 33, width: 52, height: 23)
        case .zoomLabel: return CGRect(x: b.width / 2 - 26, y: 12, width: 52, height: 19)
        }
    }

    func control(at p: CGPoint) -> Control? {
        let controls: [Control] = model.locked ? [.close, .lock] : [.close, .lock, .handle, .zoomLabel]
        return controls.first {
            rect(of: $0).contains(p) && (frame.height >= 70 || $0 != .handle) && (frame.width >= 140 || $0 != .zoomLabel)
        }
    }

    var isLocked: Bool { model.locked }

    /// Called for every pointer move: hover state, and for locked pins whether clicks reach the buttons.
    func pointer(at screenPoint: NSPoint, inside: Bool) {
        if model.hovering != inside {
            model.hovering = inside
            updateFade()
        }
        guard model.locked else { if ignoresMouseEvents { ignoresMouseEvents = false }; return }
        let local = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        let overButton = inside && control(at: local) != nil
        if ignoresMouseEvents == overButton { ignoresMouseEvents = !overButton }
    }

    func mouseDown(_ event: NSEvent, at p: CGPoint) {
        makeKey()
        downEvent = event
        downControl = control(at: p)
        if let c = downControl { model.pressed = c; return }
        guard !model.locked else { return }
        dragStart = (NSEvent.mouseLocation, frame.origin)
    }

    func mouseDragged(_ event: NSEvent, at p: CGPoint) {
        if downControl == .handle, let down = downEvent,
           hypot(event.locationInWindow.x - down.locationInWindow.x, event.locationInWindow.y - down.locationInWindow.y) > 3 {
            downControl = nil
            model.pressed = nil
            beginFileDrag(with: event)
            return
        }
        if let c = downControl { model.pressed = control(at: p) == c ? c : nil; return }
        guard let start = dragStart else { return }
        let m = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: start.origin.x + m.x - start.mouse.x, y: start.origin.y + m.y - start.mouse.y))
    }

    func mouseUp(_ event: NSEvent, at p: CGPoint) {
        defer { downControl = nil; dragStart = nil; model.pressed = nil }
        guard let c = downControl, control(at: p) == c else { return }
        switch c {
        case .close: close()
        case .lock: toggleLock()
        case .handle: break
        case .zoomLabel:
            // Clicking the zoom level opens the options (the same menu as a right-click), below the label.
            guard let view = contentView else { return }
            let r = rect(of: .zoomLabel)
            contextMenu().popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 4), in: view)
        }
    }

    func scroll(_ event: NSEvent) {
        guard !model.locked else { return }
        let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
        guard lines != 0 else { return }
        // Scrolling content up (wheel toward you) zooms in.
        setZoom(model.zoom * pow(1.2, -lines))
    }

    func magnify(_ event: NSEvent) {
        guard !model.locked else { return }
        setZoom(model.zoom * (1 + event.magnification))
    }

    private func toggleLock() {
        model.locked.toggle()
        pointer(at: NSEvent.mouseLocation, inside: frame.contains(NSEvent.mouseLocation))
        updateFade()
    }

    /// While the pointer is over a locked pin, the image fades to 25% so what's behind it shows
    /// (and can be clicked); the close and lock buttons stay opaque.
    private func updateFade() {
        let target: Float = model.locked && model.hovering ? 0.25 : 1
        guard imageLayer.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        CATransaction.setCompletionBlock { [weak self] in self?.invalidateShadow() }
        imageLayer.opacity = target
        CATransaction.commit()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if contextMenu().performKeyEquivalent(with: event) { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var origin = frame.origin
        switch Int(event.keyCode) {
        case 123: origin.x -= step
        case 124: origin.x += step
        case 125: origin.y -= step
        case 126: origin.y += step
        default: super.keyDown(with: event); return
        }
        if !model.locked { setFrameOrigin(origin) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        contextMenu().performKeyEquivalent(with: event) || super.performKeyEquivalent(with: event)
    }

    // MARK: Context menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, checked: Bool = false,
                 _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
            entry.keyEquivalentModifierMask = mods
            entry.state = checked ? .on : .off
            menu.addItem(entry)
        }
        add("Close", "w") { [weak self] in self?.close() }
        menu.addItem(.separator())
        add("Open Annotation Tool...", "e") { [weak self] in self?.annotate() }
        add("Copy to Clipboard", "c") { [weak self] in self.map { Clipboard.copy($0.item) } }
        add("Share...") { [weak self] in self?.share() }
        add("Extract text") { [weak self] in self?.extractText() }
        add("Save As...", "s") { [weak self] in
            guard let self else { return }
            NSApp.bringToFront()
            _ = FileSaver.saveWithPanel(item)
        }
        menu.addItem(.separator())
        add("Lock", "l", checked: model.locked) { [weak self] in self?.toggleLock() }
        menu.addItem(.separator())
        // Several pins on top of each other: send one behind the others (clicking a pin brings it to the front).
        add("Send to Back", "[", [.command, .shift]) { [weak self] in self.map { PinManager.shared.sendToBack($0) } }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Zoom"))
        add("50%") { [weak self] in self?.setZoom(0.5) }
        add("100%", "0") { [weak self] in self?.setZoom(1) }
        add("200%") { [weak self] in self?.setZoom(2) }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Opacity"))
        for (title, key, alpha) in [("20%", "2", 0.2), ("50%", "5", 0.5), ("100%", "0", 1.0)] {
            add(title, key, []) { [weak self] in self?.alphaValue = alpha }
        }
        menu.addItem(.separator())
        add("Shadow", checked: hasShadow) { [weak self] in self?.hasShadow.toggle(); self?.invalidateShadow() }
        add("Rounded Corners", checked: rounded) { [weak self] in self?.rounded.toggle(); self?.applyStyle() }
        add("Border", checked: bordered) { [weak self] in self?.bordered.toggle(); self?.applyStyle() }
        return menu
    }

    private func annotate() {
        let item = item
        close()
        DispatchQueue.main.async { AnnotateWindowController.open(item: item) }
    }

    private func share() {
        guard let view = contentView else { return }
        NSSharingServicePicker(items: [item.fileURL]).show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
    }

    private func extractText() {
        let item = item
        Task {
            let lines = await TextRecognizer.recognize(item.image, scale: item.scale)
            let text = TextRecognizer.text(from: lines, keepLineBreaks: Defaults[Prefs.ocrKeepLineBreaks])
            guard !text.isEmpty else { Toast.show(title: "No text found", detail: "Try selecting a larger area."); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show(title: "Text copied to clipboard", detail: text)
        }
    }

    // MARK: Drag out (the handle)

    private func beginFileDrag(with event: NSEvent) {
        guard let view = contentView else { return }
        let pbItem = NSPasteboardItem()
        pbItem.setString(item.fileURL.absoluteString, forType: .fileURL)
        pbItem.setPropertyList([item.fileURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        dragItem.setDraggingFrame(view.bounds, contents: item.nsImage)
        view.beginDraggingSession(with: [dragItem], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }
}

/// The pin's content: forwards pointer events to the window, which knows the controls.
final class PinContentView: NSView {
    weak var owner: PinWindow?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown(event, at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(event, at: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(event, at: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) { owner?.scroll(event) }
    override func magnify(with event: NSEvent) { owner?.magnify(event) }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.contextMenu() }
}

/// Draws SwiftUI without taking any events.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The hover controls: 22pt light circles for close and lock 10pt from the top corners,
/// the zoom level in a faint capsule at the top, and a 52×23pt drag handle 10pt above the bottom edge.
/// Locked pins only show close and lock.
struct PinControls: View {
    @ObservedObject var model: PinModel

    private static let fill = Color(white: 0.918).opacity(0.85)
    private static let ink = Color(white: 0.086)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                if model.hovering {
                    circle("xmark", .close, size: 10, weight: .bold).position(x: 21, y: 21)
                    circle(model.locked ? "lock.fill" : "lock.open.fill", .lock, size: 11, weight: .semibold).position(x: w - 21, y: 21)
                    if !model.locked {
                        if w >= 140 {
                            Text("\(Int((model.zoom * 100).rounded()))%")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.92))
                                .padding(.horizontal, 6)
                                .frame(height: 17)
                                // A dark capsule so the label also reads on bright images.
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                                .position(x: w / 2, y: 21.5)
                        }
                        if h >= 70 { handle.position(x: w / 2, y: h - 21.5) }
                    }
                }
            }
            .animation(.easeOut(duration: 0.15), value: model.hovering)
        }
    }

    /// Three 6×1pt lines, 4pt apart.
    private var grip: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color(white: 0.62)).frame(width: 6, height: 1) }
        }
    }

    private func circle(_ symbol: String, _ control: PinWindow.Control, size: CGFloat, weight: Font.Weight) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(Self.ink)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Self.fill))
            .overlay(Circle().fill(Color.black.opacity(model.pressed == control ? 0.15 : 0)))
            .scaleEffect(model.pressed == control ? 0.92 : 1)
    }

    private var handle: some View {
        ZStack {
            grip.offset(x: -16.5)
            Image(systemName: "doc.fill").font(.system(size: 12)).foregroundStyle(Color(white: 0.23))
            grip.offset(x: 16.5)
        }
        .frame(width: 52, height: 23)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Self.fill))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(model.pressed == .handle ? 0.15 : 0)))
    }
}
