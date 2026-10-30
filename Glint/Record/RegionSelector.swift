import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Picks the region for a recording or a scrolling capture: the screen dims (fading in) and a hint
/// pill explains what to do; drag an area (Space switches to picking a window). While dragging only the clear area
/// shows; on release the corner brackets, edge handles and the accessory panel fade in. The area stays editable
/// (move it, drag corners or edges, with resize cursors) and can be locked to an aspect ratio.
/// Return runs the primary action, Esc or a right-click cancels.
final class RegionSelector {
    /// `below`: under the area (above it when there's no room, else inside its bottom), `gap` points away.
    enum Placement { case center, bottomInside, below(gap: CGFloat) }

    /// The overlay's content view (flipped, covering `screen`).
    var overlayView: NSView { view }
    /// The selected area in global CG (top-left) coordinates, on `screen`.
    private(set) var rect: CGRect = .zero
    let screen: NSScreen
    var onCancel: (() -> Void)?
    /// Return / ⌥Return.
    var onConfirm: ((_ option: Bool) -> Void)?
    /// Called whenever the area changes (the size fields follow it).
    var onChange: ((CGRect) -> Void)?
    /// A new area is being dragged out (the mouse is still down).
    private(set) var isDrawing = false
    /// Sees key presses first; returning true consumes them (All-In-One's single-letter shortcuts).
    var onKey: ((NSEvent) -> Bool)?
    /// Width / height the area keeps while drawing and resizing; nil = freeform.
    var ratio: CGFloat? {
        get { view.ratio }
        set { view.ratio = newValue }
    }

    private let window: OverlayWindow
    private let view: RegionView
    private var accessory: NSView?
    private var placement: Placement = .center
    private var previousApp: NSRunningApplication?

    /// `dim`: how dark the surroundings get (60% for recording; All-In-One uses 50%). `level`: the
    /// All-In-One sits at 103, just above menus, so tooltips still show over it.
    init(hint: String, screen: NSScreen? = nil, dim: CGFloat = 0.6, level: NSWindow.Level? = nil) {
        self.screen = screen ?? NSScreen.withMouse ?? NSScreen.main!
        window = OverlayWindow(screen: self.screen)
        if let level { window.level = level }
        view = RegionView(frame: CGRect(origin: .zero, size: self.screen.frame.size), hint: hint)
        view.dim = dim
        view.owner = self
        window.contentView = view
    }

    func begin(initial: CGRect? = nil) {
        previousApp = NSWorkspace.shared.frontmostApplication
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        ShortcutManager.shared.setEscapeHandler { [weak self] in self?.cancel() }
        if let initial, initial.width > 20, initial.height > 20 { set(initial) }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; window.animator().alphaValue = 1 }
        NSCursor.arrow.set()
    }

    /// The panel shown with the selection (SwiftUI content gets its own hosting view).
    func setAccessory(_ accessory: NSView, placement: Placement) {
        self.accessory?.removeFromSuperview()
        self.accessory = accessory
        self.placement = placement
        accessory.wantsLayer = true
        accessory.isHidden = rect.isEmpty
        view.addSubview(accessory)
        layoutAccessory()
    }

    /// Adds a view above the dimming but below the panel (the camera).
    func addUnderlay(_ underlay: NSView) {
        if let accessory, accessory.superview === view { view.addSubview(underlay, positioned: .below, relativeTo: accessory) }
        else { view.addSubview(underlay) }
    }

    func set(_ globalRect: CGRect) {
        rect = globalRect.intersection(screen.cgFrame).integral
        view.selection = local(rect)
        view.showsChrome = !rect.isEmpty
        accessory?.isHidden = rect.isEmpty
        layoutAccessory()
        onChange?(rect)
    }

    /// Resizes the area around its center (the W × H fields). With a ratio the edited side leads and the other one
    /// follows; freeform keeps both as typed. Too big for the screen shrinks it (keeping the ratio) and slides it back on.
    func resize(to size: CGSize) {
        guard !rect.isEmpty, size.width > 0, size.height > 0 else { return }
        var s = size
        if let ratio {
            if s.width != rect.width { s.height = s.width / ratio } else { s.width = s.height * ratio }
        }
        let bounds = screen.cgFrame
        if ratio != nil {
            let f = min(1, bounds.width / s.width, bounds.height / s.height)
            s = CGSize(width: s.width * f, height: s.height * f)
        } else {
            s = CGSize(width: min(s.width, bounds.width), height: min(s.height, bounds.height))
        }
        var r = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        set(r)
    }

    /// Reshapes the area to the current ratio: keeps its height (or as much as fits) around its center.
    func applyRatio() {
        guard let ratio, !rect.isEmpty else { return }
        let bounds = screen.cgFrame
        var size = CGSize(width: rect.height * ratio, height: rect.height)
        if size.width > bounds.width { size = CGSize(width: bounds.width, height: bounds.width / ratio) }
        if size.height > bounds.height { size = CGSize(width: bounds.height * ratio, height: bounds.height) }
        var r = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        set(r)
    }

    /// Hides the overlay (the selection stays known to the caller); fades out when `animated`. `restoringFocus`
    /// gives the keyboard back to the app that was in front before.
    func end(animated: Bool = false, restoringFocus: Bool = false) {
        ShortcutManager.shared.setEscapeHandler(nil)
        NSCursor.arrow.set()
        if restoringFocus { previousApp?.activate() }
        guard animated else { window.orderOut(nil); return }
        let window = window
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; window.animator().alphaValue = 0 },
                                            completionHandler: { window.orderOut(nil) })
    }

    /// Shows an alert above the overlay.
    func runBelowAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let level = window.level
        window.level = .floating
        NSApp.activate()
        let response = alert.runModal()
        window.level = level
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        return response
    }

    func cancel() {
        end()
        previousApp?.activate()
        onCancel?()
    }

    fileprivate func confirm(option: Bool) {
        guard !rect.isEmpty else { return }
        onConfirm?(option)
    }

    fileprivate func selectionChanged(_ localRect: CGRect, dragging: Bool) {
        rect = localRect.offsetBy(dx: screen.cgFrame.minX, dy: screen.cgFrame.minY).integral
        isDrawing = dragging
        guard let accessory else { onChange?(rect); return }
        if dragging || rect.isEmpty {
            accessory.isHidden = true
            accessory.alphaValue = 0
        } else if accessory.isHidden {
            // The panel fades in once the area is released.
            accessory.isHidden = false
            accessory.alphaValue = 0
            layoutAccessory()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; accessory.animator().alphaValue = 1 }
        }
        layoutAccessory()
        onChange?(rect)
    }

    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY) }

    private func layoutAccessory() {
        guard let accessory else { return }
        let size = accessory.fittingSize
        let sel = view.selection
        var origin: CGPoint
        switch placement {
        case .center:
            origin = CGPoint(x: sel.midX - size.width / 2, y: sel.midY - size.height / 2)
            // Too small to hold the panel: put it below (or above) the area.
            if sel.width < size.width + 20 || sel.height < size.height + 20 {
                origin.y = sel.maxY + 12 + size.height <= view.bounds.height ? sel.maxY + 12 : sel.minY - 12 - size.height
            }
        case .bottomInside:
            origin = CGPoint(x: sel.midX - size.width / 2, y: sel.maxY - 16 - size.height)
        case .below(let gap):
            origin = CGPoint(x: sel.midX - size.width / 2, y: sel.maxY + gap)
            if origin.y + size.height > view.bounds.height - 8 {
                origin.y = sel.minY - gap - size.height
                if origin.y < 8 { origin.y = sel.maxY - 16 - size.height }
            }
        }
        origin.x = min(max(origin.x, 8), view.bounds.width - size.width - 8)
        origin.y = min(max(origin.y, 8), view.bounds.height - size.height - 8)
        accessory.frame = CGRect(origin: origin, size: size)
    }
}

/// Dims the screen except the selection and draws the corner brackets and edge handles (flipped coordinates).
private final class RegionView: NSView {
    weak var owner: RegionSelector?
    var selection: CGRect = .zero { didSet { needsDisplay = true; updateHint() } }
    /// Brackets and handles: hidden while the area is being drawn.
    var showsChrome = false { didSet { needsDisplay = true } }
    var ratio: CGFloat?
    var dim: CGFloat = 0.6
    private let hintView: NSView
    private var windows = WindowInfo.onScreen()
    private var windowMode = false
    private var hoveredWindow: CGRect?
    private enum Drag { case create(CGPoint), move(CGPoint, CGRect), resize(Edge, CGRect) }
    private struct Edge: OptionSet { let rawValue: Int; static let left = Edge(rawValue: 1), right = Edge(rawValue: 2), top = Edge(rawValue: 4), bottom = Edge(rawValue: 8) }
    private var drag: Drag?
    private var hintHovered = false

    init(frame: CGRect, hint: String) {
        let pill = PassThroughHostingView(rootView: HintPill(text: hint))
        pill.sizingOptions = [.intrinsicContentSize]
        pill.wantsLayer = true
        hintView = pill
        super.init(frame: frame)
        addSubview(pill)
        let size = pill.fittingSize
        pill.frame = CGRect(x: (frame.width - size.width) / 2, y: (frame.height - size.height) / 2, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateHint() {
        hintView.isHidden = !selection.isEmpty || drag != nil
        if hintView.isHidden { hintHovered = false; hintView.alphaValue = 1 }
    }

    /// The hint fades almost away (to 10%) while the pointer is near it: its hover zone
    /// reaches ~52pt past the pill's sides and bottom and ~65pt above it. The fade starts at once and takes 0.1 s.
    private func updateHintHover(_ p: CGPoint) {
        let zone = hintView.frame.insetBy(dx: -52, dy: -57).offsetBy(dx: 2, dy: -8)
        let hovered = !hintView.isHidden && zone.contains(p)
        guard hovered != hintHovered else { return }
        hintHovered = hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            hintView.animator().alphaValue = hovered ? 0.1 : 1
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .cursorUpdate], owner: self))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(dim).cgColor)
        ctx.addRect(bounds)
        if !selection.isEmpty { ctx.addRect(selection) }
        if windowMode, let w = hoveredWindow { ctx.addRect(w) }
        ctx.fillPath(using: .evenOdd)
        if windowMode, let w = hoveredWindow {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor)
            ctx.fill(w)
        }
        guard !selection.isEmpty, showsChrome else { return }
        // Corner brackets (3pt, 16pt arms) just outside the area and short bars centered on each edge.
        let r = selection, t: CGFloat = 3, arm: CGFloat = 16
        ctx.setFillColor(NSColor.white.cgColor)
        for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            ctx.fill(CGRect(x: sx > 0 ? x - t : x - arm + t, y: sy > 0 ? y - t : y, width: arm, height: t).standardized)
            ctx.fill(CGRect(x: sx > 0 ? x - t : x, y: sy > 0 ? y - t : y - arm + t, width: t, height: arm).standardized)
        }
        let bar: CGFloat = 14
        ctx.fill(CGRect(x: r.midX - bar / 2, y: r.minY - t, width: bar, height: t))
        ctx.fill(CGRect(x: r.midX - bar / 2, y: r.maxY, width: bar, height: t))
        ctx.fill(CGRect(x: r.minX - t, y: r.midY - bar / 2, width: t, height: bar))
        ctx.fill(CGRect(x: r.maxX, y: r.midY - bar / 2, width: t, height: bar))
    }

    private func edges(at p: CGPoint) -> Edge {
        guard !selection.isEmpty, showsChrome else { return [] }
        let r = selection.insetBy(dx: -8, dy: -8)
        guard r.contains(p) else { return [] }
        var e: Edge = []
        if abs(p.x - selection.minX) < 8 { e.insert(.left) }
        if abs(p.x - selection.maxX) < 8 { e.insert(.right) }
        if abs(p.y - selection.minY) < 8 { e.insert(.top) }
        if abs(p.y - selection.maxY) < 8 { e.insert(.bottom) }
        return e
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    /// macOS's frame-resize arrows on corners and edges, an open hand inside, otherwise the arrow.
    private func updateCursor(_ p: CGPoint) {
        if windowMode { NSCursor.pointingHand.set(); return }
        // Over the panel or the camera: their own cursor. Over another window (the settings popover, a menu) the
        // area underneath must not change it either: plain arrow.
        if NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) != window?.windowNumber {
            NSCursor.arrow.set()
            return
        }
        if let superview, let hit = hitTest(convert(p, to: superview)), hit !== self { NSCursor.arrow.set(); return }
        let e = edges(at: p)
        let position: NSCursor.FrameResizePosition? = switch e {
        case [.top, .left]: .topLeft
        case [.top, .right]: .topRight
        case [.bottom, .left]: .bottomLeft
        case [.bottom, .right]: .bottomRight
        case [.top]: .top
        case [.bottom]: .bottom
        case [.left]: .left
        case [.right]: .right
        default: nil
        }
        if let position { NSCursor.frameResize(position: position, directions: .all).set() }
        else if showsChrome, selection.contains(p) { NSCursor.openHand.set() }
        else { NSCursor.arrow.set() }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateCursor(p)
        updateHintHover(p)
        guard windowMode, let screen = owner?.screen else { return }
        let g = CGPoint(x: p.x + screen.cgFrame.minX, y: p.y + screen.cgFrame.minY)
        hoveredWindow = windows.first { $0.frame.contains(g) }.map { $0.frame.offsetBy(dx: -screen.cgFrame.minX, dy: -screen.cgFrame.minY) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if windowMode {
            windowMode = false
            if let w = hoveredWindow {
                selection = w.intersection(bounds)
                showsChrome = true
                owner?.selectionChanged(selection, dragging: false)
            }
            hoveredWindow = nil
            needsDisplay = true
            return
        }
        let e = edges(at: p)
        if !e.isEmpty { drag = .resize(e, selection) }
        else if showsChrome, selection.contains(p) { drag = .move(p, selection); NSCursor.closedHand.set() }
        else { drag = .create(p); updateHint() }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let c = CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
        switch drag {
        case .create(let start):
            showsChrome = false
            selection = ratio.map { constrained(from: start, to: c, ratio: $0) } ?? CGRect(corner: start, c)
            owner?.selectionChanged(selection, dragging: true)
            return
        case .move(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            selection = r
        case .resize(let e, let original):
            selection = ratio.map { resized(original, edges: e, to: c, ratio: $0) } ?? {
                var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
                if e.contains(.left) { minX = c.x }
                if e.contains(.right) { maxX = c.x }
                if e.contains(.top) { minY = c.y }
                if e.contains(.bottom) { maxY = c.y }
                return CGRect(corner: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY))
            }()
        case nil:
            return
        }
        owner?.selectionChanged(selection, dragging: false)
    }

    override func mouseUp(with event: NSEvent) {
        if case .create = drag {
            if selection.width < 8 || selection.height < 8 { selection = .zero }
            showsChrome = !selection.isEmpty
        }
        drag = nil
        updateHint()
        owner?.selectionChanged(selection, dragging: false)
        updateCursor(convert(event.locationInWindow, from: nil))
    }

    // MARK: Ratio

    /// The largest ratio-shaped box from `start` toward `p` that stays on screen.
    private func constrained(from start: CGPoint, to p: CGPoint, ratio: CGFloat) -> CGRect {
        var w = abs(p.x - start.x), h = abs(p.y - start.y)
        if w / max(h, 1) > ratio { w = h * ratio } else { h = w / ratio }
        let maxW = p.x >= start.x ? bounds.width - start.x : start.x
        let maxH = p.y >= start.y ? bounds.height - start.y : start.y
        let f = min(1, maxW / max(w, 1), maxH / max(h, 1))
        w *= f; h *= f
        return CGRect(x: p.x >= start.x ? start.x : start.x - w, y: p.y >= start.y ? start.y : start.y - h, width: w, height: h)
    }

    /// Corner drags keep the opposite corner; edge drags keep the opposite edge and stay centered across it.
    private func resized(_ r: CGRect, edges e: Edge, to p: CGPoint, ratio: CGFloat) -> CGRect {
        var out: CGRect
        if e.contains(.left) || e.contains(.right), e.contains(.top) || e.contains(.bottom) {
            let anchor = CGPoint(x: e.contains(.left) ? r.maxX : r.minX, y: e.contains(.top) ? r.maxY : r.minY)
            return constrained(from: anchor, to: p, ratio: ratio)
        } else if e.contains(.top) || e.contains(.bottom) {
            let h = max(abs(p.y - (e.contains(.top) ? r.maxY : r.minY)), 8), w = h * ratio
            out = CGRect(x: r.midX - w / 2, y: e.contains(.top) ? r.maxY - h : r.minY, width: w, height: h)
        } else {
            let w = max(abs(p.x - (e.contains(.left) ? r.maxX : r.minX)), 8), h = w / ratio
            out = CGRect(x: e.contains(.left) ? r.maxX - w : r.minX, y: r.midY - h / 2, width: w, height: h)
        }
        // Too big for the screen: shrink (keeping the ratio), then slide back on screen.
        let f = min(1, bounds.width / out.width, bounds.height / out.height)
        if f < 1 { out = CGRect(x: out.midX - out.width * f / 2, y: out.midY - out.height * f / 2, width: out.width * f, height: out.height * f) }
        out.origin.x = min(max(out.minX, 0), bounds.width - out.width)
        out.origin.y = min(max(out.minY, 0), bounds.height - out.height)
        return out
    }

    override func rightMouseDown(with event: NSEvent) { owner?.cancel() }

    override func keyDown(with event: NSEvent) {
        if owner?.onKey?(event) == true { return }
        switch Int(event.keyCode) {
        case kVK_Escape: owner?.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter: owner?.confirm(option: event.modifierFlags.contains(.option))
        case kVK_Space:
            windowMode.toggle()
            windows = WindowInfo.onScreen()
            hoveredWindow = nil
            needsDisplay = true
        default: super.keyDown(with: event)
        }
    }
}

/// The light hint pill in the middle of the screen ("Drag to record a part of the screen. …").
private struct HintPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Color(white: 0.12))
            .padding(.horizontal, 28)
            .frame(height: 60)
            .background(Capsule().fill(Color(white: 0.84).opacity(0.97)))
            .fixedSize()
    }
}
