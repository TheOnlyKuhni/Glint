import AppKit
import Carbon.HIToolbox
import QuartzCore

struct SelectionResult {
    enum Target {
        case area(CGRect)                   // global CG coordinates, points
        case window(CGWindowID, CGRect)     // id + frame in global CG coordinates
    }
    let target: Target
    let screen: NSScreen
}

/// An on-screen window that can be picked in window mode.
struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect  // global CG coordinates
    var pid: pid_t = 0

    /// On-screen windows of other apps, front to back.
    static func onScreen() -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let list = raw as? [[String: Any]] ?? []
        let pid = ProcessInfo.processInfo.processIdentifier
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= 0, layer < menuLevel,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != pid,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            if ["Dock", "Window Server", "WindowManager"].contains(ownerName) { return nil }
            return WindowInfo(id: id, frame: bounds, pid: owner)
        }
    }
}

/// Whether Mission Control is on screen: it shows as a full-screen window of the Dock at the Dock's level (checked
/// at most every 0.2 s).
enum MissionControl {
    private static var checked = Date.distantPast
    private static var active = false

    static var isActive: Bool {
        guard Date().timeIntervalSince(checked) > 0.2 else { return active }
        checked = Date()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        active = list.contains { info in
            guard info[kCGWindowOwnerName as String] as? String == "Dock", info[kCGWindowLayer as String] as? Int == dockLevel,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return false }
            return NSScreen.screens.contains { $0.frame.size == bounds.size }
        }
        return active
    }
}

/// Full-screen overlays (one per display) for picking an area or a window.
final class SelectionOverlay {
    enum Mode { case area, window }

    fileprivate(set) var mode: Mode
    fileprivate let snapshots: [CGDirectDisplayID: CGImage]
    fileprivate let showsSnapshot: Bool
    fileprivate private(set) var windows: [WindowInfo]
    private var windowsRead = Date()
    private var overlayWindows: [OverlayWindow] = []
    private var missionControlTimer: Timer?
    private var inMissionControl = false
    private var missionControlClick: Any?
    private var clickedInMissionControl = false
    private var completion: ((SelectionResult?) -> Void)?
    private var previousApp: NSRunningApplication?

    /// - Parameters:
    ///   - snapshots: per-display images for freezing the screen and the magnifier.
    ///   - showsSnapshot: draw the snapshot under the overlay (freeze screen).
    init(mode: Mode, snapshots: [CGDirectDisplayID: CGImage] = [:], showsSnapshot: Bool = false) {
        self.mode = mode
        self.snapshots = snapshots
        self.showsSnapshot = showsSnapshot
        self.windows = WindowInfo.onScreen()
    }

    func begin(completion: @escaping (SelectionResult?) -> Void) {
        self.completion = completion
        previousApp = NSWorkspace.shared.frontmostApplication
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let view = SelectionView(overlay: self, screen: screen, snapshot: snapshots[screen.displayID])
            window.contentView = view
            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
        ShortcutManager.shared.setEscapeHandler { [weak self] in self?.finish(nil) }
        NSApp.activate()
        let mouseScreen = NSScreen.withMouse
        let keyWindow = overlayWindows.first { $0.screen == mouseScreen } ?? overlayWindows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
        for window in overlayWindows { (window.contentView as? SelectionView)?.refreshFromMouse() }
        GlintCrosshair.cursor.set()
        missionControlTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMissionControl() }
        }
    }

    /// The windows front to back, read again at most every 0.25 s (unless the screen is frozen), so the hovered
    /// window is always the one really on top, also after windows moved or Mission Control reordered them.
    fileprivate func currentWindows() -> [WindowInfo] {
        if !showsSnapshot, Date().timeIntervalSince(windowsRead) > 0.25 {
            windows = WindowInfo.onScreen()
            windowsRead = Date()
        }
        return windows
    }

    /// Window mode during Mission Control (e.g. a three-finger swipe up): the overlay steps aside so Mission Control
    /// highlights the window under the pointer itself; clicking one brings it to the front, Mission Control closes,
    /// and that window is captured.
    private func checkMissionControl() {
        guard completion != nil, mode == .window else { return }
        let active = MissionControl.isActive
        guard active != inMissionControl else { return }
        inMissionControl = active
        if active {
            clickedInMissionControl = false
            for window in overlayWindows { window.ignoresMouseEvents = true; window.alphaValue = 0 }
            missionControlClick = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.clickedInMissionControl = true }
            }
            return
        }
        if let missionControlClick { NSEvent.removeMonitor(missionControlClick) }
        missionControlClick = nil
        guard clickedInMissionControl else {
            for window in overlayWindows { window.ignoresMouseEvents = false; window.alphaValue = 1 }
            return
        }
        // Give the picked window a moment to come to the front, then take the frontmost app's top window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.completion != nil else { return }
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let list = WindowInfo.onScreen()
            guard let picked = list.first(where: { $0.pid == pid }) ?? list.first,
                  let screen = NSScreen.containing(cgRect: picked.frame) ?? NSScreen.main else {
                for window in self.overlayWindows { window.ignoresMouseEvents = false; window.alphaValue = 1 }
                return
            }
            self.finish(SelectionResult(target: .window(picked.id, picked.frame), screen: screen))
        }
    }

    fileprivate func toggleMode() {
        mode = mode == .area ? .window : .area
        for window in overlayWindows { (window.contentView as? SelectionView)?.refreshFromMouse() }
    }

    fileprivate func makeKey(_ window: NSWindow) {
        guard !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    fileprivate func refreshAll() {
        for window in overlayWindows { (window.contentView as? SelectionView)?.refreshFromMouse() }
    }

    fileprivate func finish(_ result: SelectionResult?) {
        guard let completion else { return }
        self.completion = nil
        missionControlTimer?.invalidate()
        if let missionControlClick { NSEvent.removeMonitor(missionControlClick) }
        missionControlClick = nil
        ShortcutManager.shared.setEscapeHandler(nil)
        for window in overlayWindows { window.orderOut(nil) }
        overlayWindows.removeAll()
        NSCursor.arrow.set()
        if result == nil { previousApp?.activate() }
        completion(result)
    }
}

/// Non-activating so it can take keyboard focus even when macOS refuses to activate Glint.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        // Transparent windows let clicks fall through unless this is set explicitly.
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Draws the selection UI for one display. Uses flipped (top-left origin) coordinates, matching CG.
private final class SelectionView: NSView {
    private unowned let overlay: SelectionOverlay
    private let screen: NSScreen
    private let snapshot: CGImage?

    private var mouse: CGPoint = .zero
    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var isMovingSelection = false
    private var moveAnchor: CGPoint = .zero
    private var hoveredWindow: WindowInfo?
    private var isCommandHeld = false

    private let snapshotLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let sizeLabel = SizeLabelView()
    private let magnifier: MagnifierView?

    init(overlay: SelectionOverlay, screen: NSScreen, snapshot: CGImage?) {
        self.overlay = overlay
        self.screen = screen
        self.snapshot = snapshot
        magnifier = (Defaults[Prefs.showMagnifier] && snapshot != nil) ? MagnifierView(image: snapshot!, scale: screen.backingScaleFactor) : nil
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        setUpLayers()
        addSubview(sizeLabel)
        sizeLabel.isHidden = true
        if let magnifier { addSubview(magnifier); magnifier.isHidden = true }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setUpLayers() {
        guard let layer else { return }
        let scale = screen.backingScaleFactor
        if overlay.showsSnapshot, let snapshot {
            snapshotLayer.contents = snapshot
            snapshotLayer.frame = bounds
            snapshotLayer.contentsGravity = .resize
            layer.addSublayer(snapshotLayer)
        }
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        highlightLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        highlightLayer.strokeColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        highlightLayer.lineWidth = 1
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        borderLayer.lineWidth = 1
        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.75).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.shadowColor = NSColor.black.cgColor
        crosshairLayer.shadowOpacity = 0.6
        crosshairLayer.shadowRadius = 0.5
        crosshairLayer.shadowOffset = .zero
        for sub in [dimLayer, highlightLayer, borderLayer, crosshairLayer] {
            sub.contentsScale = scale
            sub.actions = ["path": NSNull(), "hidden": NSNull()]
            layer.addSublayer(sub)
        }
    }

    // MARK: Coordinates

    private func globalCG(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: screen.cgFrame.minX, dy: screen.cgFrame.minY) }
    private func local(_ globalRect: CGRect) -> CGRect { globalRect.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY) }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    /// Snaps to the device pixel grid so captures don't straddle pixels.
    private func snap(_ p: CGPoint) -> CGPoint {
        let s = screen.backingScaleFactor
        return CGPoint(x: (p.x * s).rounded() / s, y: (p.y * s).rounded() / s)
    }

    func refreshFromMouse() {
        guard let window else { return }
        let p = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        mouse = convert(p, from: nil)
        updateHover()
        render()
    }

    // MARK: Events

    override func cursorUpdate(with event: NSEvent) { GlintCrosshair.cursor.set() }

    override func mouseEntered(with event: NSEvent) {
        if let window { overlay.makeKey(window) }
        GlintCrosshair.cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        mouse = CGPoint(x: -1000, y: -1000)
        hoveredWindow = nil
        if dragStart == nil { render() }
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        render()
    }

    override func mouseDown(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if overlay.mode == .area {
            dragStart = snap(clamp(mouse))
            selection = nil
        }
        render()
    }

    override func mouseDragged(with event: NSEvent) {
        mouse = clamp(convert(event.locationInWindow, from: nil))
        guard overlay.mode == .area, let start = dragStart else { return }
        if isMovingSelection, let current = selection {
            var moved = current.offsetBy(dx: mouse.x - moveAnchor.x, dy: mouse.y - moveAnchor.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            moveAnchor = mouse
            selection = moved
            dragStart = CGPoint(x: moved.minX, y: moved.minY)
        } else {
            var end = mouse
            let flags = event.modifierFlags
            if flags.contains(.shift) {
                // Lock to a square.
                let side = max(abs(end.x - start.x), abs(end.y - start.y))
                end = CGPoint(x: start.x + (end.x >= start.x ? side : -side), y: start.y + (end.y >= start.y ? side : -side))
            }
            if flags.contains(.option) {
                // Resize from the center.
                let dx = end.x - start.x, dy = end.y - start.y
                selection = CGRect(corner: snap(CGPoint(x: start.x - dx, y: start.y - dy)), snap(end))
            } else {
                selection = CGRect(corner: start, snap(end))
            }
        }
        render()
    }

    override func mouseUp(with event: NSEvent) {
        switch overlay.mode {
        case .area:
            defer { dragStart = nil }
            guard let selection, selection.width >= 4, selection.height >= 4 else {
                self.selection = nil
                render()
                return
            }
            overlay.finish(SelectionResult(target: .area(globalCG(selection)), screen: screen))
        case .window:
            guard let hovered = hoveredWindow else { return }
            overlay.finish(SelectionResult(target: .window(hovered.id, hovered.frame), screen: screen))
        }
    }

    override func rightMouseDown(with event: NSEvent) { overlay.finish(nil) }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            overlay.finish(nil)
        case kVK_Space:
            if dragStart != nil, selection != nil {
                if !isMovingSelection { isMovingSelection = true; moveAnchor = mouse }
            } else if !event.isARepeat {
                overlay.toggleMode()
            }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudgeCursor(keyCode: Int(event.keyCode), step: event.modifierFlags.contains(.shift) ? 10 : 1)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space { isMovingSelection = false }
    }

    override func flagsChanged(with event: NSEvent) {
        isCommandHeld = event.modifierFlags.contains(.command)
        render()
    }

    private func nudgeCursor(keyCode: Int, step: CGFloat) {
        var p = Geometry.cgPoint(fromAppKit: NSEvent.mouseLocation)
        switch keyCode {
        case kVK_LeftArrow: p.x -= step
        case kVK_RightArrow: p.x += step
        case kVK_UpArrow: p.y -= step
        default: p.y += step
        }
        CGWarpMouseCursorPosition(p)
        mouse = CGPoint(x: p.x - screen.cgFrame.minX, y: p.y - screen.cgFrame.minY)
        updateHover()
        render()
    }

    private func updateHover() {
        guard overlay.mode == .window, !MissionControl.isActive else { hoveredWindow = nil; return }
        let global = CGPoint(x: mouse.x + screen.cgFrame.minX, y: mouse.y + screen.cgFrame.minY)
        hoveredWindow = overlay.currentWindows().first { $0.frame.contains(global) }
    }

    // MARK: Rendering

    private var showsCrosshair: Bool {
        switch Defaults[Prefs.crosshairMode] {
        case .disabled: false
        case .always: true
        case .holdingShift: isCommandHeld
        }
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let mouseInside = bounds.contains(mouse)
        switch overlay.mode {
        case .area:
            highlightLayer.isHidden = true
            if let selection {
                let dim = CGMutablePath()
                dim.addRect(bounds)
                dim.addRect(selection)
                dimLayer.path = dim
                dimLayer.isHidden = false
                borderLayer.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
                borderLayer.isHidden = false
            } else {
                dimLayer.isHidden = true
                borderLayer.isHidden = true
            }
        case .window:
            borderLayer.isHidden = true
            if let hovered = hoveredWindow, mouseInside {
                let r = local(hovered.frame)
                let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 10, cornerHeight: 10, transform: nil)
                highlightLayer.path = path
                highlightLayer.isHidden = false
            } else {
                highlightLayer.isHidden = true
            }
            dimLayer.isHidden = true
        }

        // Crosshair lines across the display.
        if showsCrosshair, mouseInside, overlay.mode == .area {
            let path = CGMutablePath()
            let x = (mouse.x.rounded(.down)) + 0.5, y = (mouse.y.rounded(.down)) + 0.5
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: bounds.width, y: y))
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: bounds.height))
            crosshairLayer.path = path
            crosshairLayer.isHidden = false
        } else {
            crosshairLayer.isHidden = true
        }

        // Size / position label next to the cursor.
        if mouseInside, overlay.mode == .area {
            if let selection {
                sizeLabel.text = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
            } else {
                sizeLabel.text = "\(Int(mouse.x.rounded())), \(Int(mouse.y.rounded()))"
            }
            sizeLabel.isHidden = false
            placeNearCursor(sizeLabel, offset: CGPoint(x: 14, y: 16))
        } else {
            sizeLabel.isHidden = true
        }

        if let magnifier {
            magnifier.isHidden = !(mouseInside && overlay.mode == .area && showsCrosshair)
            if !magnifier.isHidden {
                magnifier.center = mouse
                placeNearCursor(magnifier, offset: CGPoint(x: 18, y: 40))
            }
        }
    }

    private func placeNearCursor(_ view: NSView, offset: CGPoint) {
        let size = view.fittingSize
        var origin = CGPoint(x: mouse.x + offset.x, y: mouse.y + offset.y)
        if origin.x + size.width > bounds.width - 4 { origin.x = mouse.x - offset.x - size.width }
        if origin.y + size.height > bounds.height - 4 { origin.y = mouse.y - offset.y - size.height }
        view.frame = CGRect(origin: origin, size: size)
    }
}

/// Glint's selection cursor (Capture Area, Timer, Capture Text): four short rounded arms around an open center with
/// a dot, white on a soft dark halo so it reads on any background. The coordinate pill beside it is `SizeLabelView`.
enum GlintCrosshair {
    static let cursor: NSCursor = {
        let size: CGFloat = 31, c = size / 2, gap: CGFloat = 4, arm: CGFloat = 12
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineCap(.round)
            func arms() {
                for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                    ctx.move(to: CGPoint(x: c + dx * gap, y: c + dy * gap))
                    ctx.addLine(to: CGPoint(x: c + dx * arm, y: c + dy * arm))
                }
            }
            // Halo, then the white cross and center dot.
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(3.5)
            arms(); ctx.strokePath()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.fillEllipse(in: CGRect(x: c - 2.25, y: c - 2.25, width: 4.5, height: 4.5))
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            arms(); ctx.strokePath()
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: c - 1, y: c - 1, width: 2, height: 2))
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: c, y: c))
    }()
}

/// Dark rounded pill beside the cursor with the position ("x, y") or the selection size ("W × H"), in the
/// editor's toolbar type: 12pt medium, tabular digits.
private final class SizeLabelView: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue; invalidateIntrinsicContentSize() }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 0.5
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Pixel loupe drawn from the frozen snapshot.
private final class MagnifierView: NSView {
    private let image: CGImage
    private let scale: CGFloat
    private let pixelsAcross = 15
    private let zoom: CGFloat = 8
    var center: CGPoint = .zero { didSet { needsDisplay = true } }

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 1.5
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: CGFloat(pixelsAcross) * zoom, height: CGFloat(pixelsAcross) * zoom) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let half = pixelsAcross / 2
        let px = Int((center.x * scale).rounded(.down)), py = Int((center.y * scale).rounded(.down))
        let crop = CGRect(x: px - half, y: py - half, width: pixelsAcross, height: pixelsAcross)
        NSColor.black.setFill()
        bounds.fill()
        if let piece = image.cropping(to: crop.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))) {
            ctx.interpolationQuality = .none
            let dx = CGFloat(max(0, -crop.minX)) * zoom, dy = CGFloat(max(0, -crop.minY)) * zoom
            let target = CGRect(x: dx, y: dy, width: CGFloat(piece.width) * zoom, height: CGFloat(piece.height) * zoom)
            NSImage(cgImage: piece, size: .zero).draw(in: target, from: .zero, operation: .copy, fraction: 1,
                                                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        // Center pixel outline.
        let c = CGRect(x: CGFloat(half) * zoom, y: CGFloat(half) * zoom, width: zoom, height: zoom)
        NSColor.white.setStroke()
        let path = NSBezierPath(rect: c.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }
}
