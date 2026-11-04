import AppKit
import SwiftUI

/// State of Crop & Resize mode: crop rectangle (image points; it may lie anywhere, past the screenshot it's the
/// fill), ratio and output size.
@Observable
final class CropState {
    enum Ratio: String, CaseIterable, Identifiable {
        case freeform, customRatio, original, square, r4x3, r3x2, r16x9, r16x10, r3x4, r2x3, r9x16
        var id: String { rawValue }
        var title: String {
            switch self {
            case .freeform: "Freeform"
            case .customRatio: "Custom Ratio"
            case .original: "Original"
            case .square: "Square"
            case .r4x3: "4:3"
            case .r3x2: "3:2"
            case .r16x9: "16:9"
            case .r16x10: "16:10"
            case .r3x4: "3:4"
            case .r2x3: "2:3"
            case .r9x16: "9:16"
            }
        }
        func value(original: CGSize) -> CGFloat? {
            switch self {
            case .freeform, .customRatio: nil
            case .original: original.width / original.height
            case .square: 1
            case .r4x3: 4.0 / 3
            case .r3x2: 3.0 / 2
            case .r16x9: 16.0 / 9
            case .r16x10: 16.0 / 10
            case .r3x4: 3.0 / 4
            case .r2x3: 2.0 / 3
            case .r9x16: 9.0 / 16
            }
        }
    }

    /// What fills the parts of the crop outside the screenshot.
    enum Fill: Equatable {
        case transparent, auto, white, gray, black, custom(UInt32)
        var title: String {
            switch self {
            case .transparent: "Transparent"
            case .auto: "Auto"
            case .white: "White"
            case .gray: "Gray"
            case .black: "Black"
            case .custom: "Custom Color..."
            }
        }

        /// The fill color for `image`, nil = transparent.
        func color(for image: CGImage) -> CGColor? {
            switch self {
            case .transparent: nil
            case .auto: BackgroundStyle.edgeColor(of: image)
            case .white: CGColor(gray: 1, alpha: 1)
            case .gray: CGColor(gray: 0.5, alpha: 1)
            case .black: CGColor(gray: 0, alpha: 1)
            case .custom(let hex): BackgroundPalette.nsColor(hex).cgColor
            }
        }
    }

    var rect: CGRect
    /// Freeform (the default): the handles change the frame freely and the ratio fields stay blank. A typed or
    /// picked ratio locks the frame to it; a typed one that matches a preset becomes that preset, else Custom Ratio.
    var ratio: Ratio = .freeform
    /// The terms typed into the ratio fields (0 = that field is blank); the ratio of Custom Ratio.
    var typedRatio: CGSize?
    /// The custom ratio last typed: Custom brings it back after another ratio was picked.
    var lastCustomRatio: CGSize?
    var fill: Fill = .auto
    /// Output scale per axis relative to the crop (Image size popover).
    var outputScaleX: CGFloat = 1
    var outputScaleY: CGFloat = 1
    /// Image size: editing one side scales the other along.
    var lockOutputRatio = true
    var outputInPercent = false
    var snapToEdges = true
    /// Pixels per point of the screenshot (the fields show pixels).
    var pixelScale: CGFloat = 2
    var imageSize: CGSize

    /// Largest crop and output side in pixels (memory).
    static let maxPixels: CGFloat = 16_384
    private var maxCrop: CGFloat { Self.maxPixels / pixelScale }

    init(imageSize: CGSize) {
        self.imageSize = imageSize
        rect = CGRect(origin: .zero, size: imageSize)
    }

    /// Width / height the frame keeps, nil = freeform.
    var ratioValue: CGFloat? {
        if ratio == .customRatio, let t = typedRatio, t.width > 0, t.height > 0 { return t.width / t.height }
        return ratio.value(original: imageSize)
    }

    /// What the two ratio fields show ("" = blank).
    var ratioTerms: (String, String) {
        if let t = typedRatio { return (Self.term(t.width), Self.term(t.height)) }
        switch ratio {
        case .freeform, .customRatio: return ("", "")
        case .original:
            let w = Int((imageSize.width * pixelScale).rounded()), h = Int((imageSize.height * pixelScale).rounded())
            let g = Self.gcd(w, h)
            return (String(w / max(g, 1)), String(h / max(g, 1)))
        case .square: return ("1", "1")
        default:
            let parts = ratio.title.split(separator: ":").map(String.init)
            return (parts.first ?? "", parts.last ?? "")
        }
    }

    private static func term(_ v: CGFloat) -> String { v <= 0 ? "" : v == v.rounded() ? String(Int(v)) : String(format: "%g", Double(v)) }
    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Rotate (90° clockwise) or Flip turned the screenshot itself: the crop frame turns with it.
    func imageTransformed(rotated: Bool, newSize: CGSize) {
        let old = imageSize, r = rect
        imageSize = newSize
        rect = rotated ? CGRect(x: old.height - r.maxY, y: r.minX, width: r.height, height: r.width)
                       : CGRect(x: old.width - r.maxX, y: r.minY, width: r.width, height: r.height)
        guard rotated else { return }
        swap(&outputScaleX, &outputScaleY)
        // A fixed ratio turns too (16:9 → 9:16, a custom 2:5 → 5:2).
        if let t = typedRatio { typedRatio = CGSize(width: t.height, height: t.width) }
        else if ratio != .freeform, ratio != .original, ratio != .square {
            let (a, b) = ratioTerms
            resolve(CGSize(width: CGFloat(Double(b) ?? 0), height: CGFloat(Double(a) ?? 0)))
        }
    }

    /// The screenshot turned 90° clockwise or mirrored left–right (pixels).
    static func transform(_ image: CGImage, rotate: Bool) -> CGImage? {
        let w = rotate ? image.height : image.width, h = rotate ? image.width : image.height
        guard let ctx = ImageProcessing.context(width: w, height: h, colorSpace: image.colorSpace) else { return nil }
        if rotate {
            // Bottom-left origin: turning the content clockwise on screen is a -90° rotation.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// The fill color for `image`, nil = transparent.
    func fillColor(for image: CGImage) -> CGColor? { fill.color(for: image) }

    /// Final size in pixels (Image size).
    var outputPixels: CGSize {
        let w = (rect.width * pixelScale * outputScaleX).rounded(), h = (rect.height * pixelScale * outputScaleY).rounded()
        return CGSize(width: min(max(w, 1), Self.maxPixels), height: min(max(h, 1), Self.maxPixels))
    }

    /// Picks a ratio from the menu: the frame shrinks around its center to it. Custom Ratio takes the frame's
    /// current ratio.
    func apply(_ ratio: Ratio) {
        if self.ratio == .customRatio, let t = typedRatio, t.width > 0, t.height > 0 { lastCustomRatio = t }
        typedRatio = nil
        if ratio == .customRatio {
            // The one typed before, else the frame's current ratio.
            if let last = lastCustomRatio {
                typedRatio = last
            } else {
                let w = Int((rect.width * pixelScale).rounded()), h = Int((rect.height * pixelScale).rounded()), g = max(Self.gcd(w, h), 1)
                typedRatio = CGSize(width: w / g, height: h / g)
            }
        }
        self.ratio = ratio
        fitRatio(keepWidth: nil)
    }

    /// Complete terms → the preset they match, else Custom Ratio.
    private func resolve(_ t: CGSize) {
        let value = t.width / t.height
        let fixed: [Ratio] = [.square, .r4x3, .r3x2, .r16x9, .r16x10, .r3x4, .r2x3, .r9x16]
        if let preset = fixed.first(where: { abs(($0.value(original: imageSize) ?? 0) - value) < 0.0005 }) {
            ratio = preset
            typedRatio = nil
        } else {
            ratio = .customRatio
            typedRatio = t
        }
    }

    /// A term of the custom ratio was typed (`width` = the first field; nil = cleared). Once both are set the ratio
    /// applies by changing the edited axis. It stays Custom (also when it equals a preset) and is remembered.
    func setRatioTerm(_ value: CGFloat?, width: Bool) {
        var t = typedRatio ?? {
            let (a, b) = ratioTerms
            return CGSize(width: CGFloat(Double(a) ?? 0), height: CGFloat(Double(b) ?? 0))
        }()
        if width { t.width = max(value ?? 0, 0) } else { t.height = max(value ?? 0, 0) }
        ratio = .customRatio
        typedRatio = t
        guard t.width > 0, t.height > 0 else { return }
        lastCustomRatio = t
        fitRatio(keepWidth: !width)
    }

    /// Makes the frame match `ratioValue`: changes the height (keepWidth true), the width (false), or shrinks
    /// around the center (nil).
    private func fitRatio(keepWidth: Bool?) {
        guard let r = ratioValue else { return }
        var size = rect.size
        switch keepWidth {
        case true?: size.height = size.width / r
        case false?: size.width = size.height * r
        case nil: if size.width / size.height > r { size.width = size.height * r } else { size.height = size.width / r }
        }
        let center = keepWidth == nil ? CGPoint(x: rect.midX, y: rect.midY) : nil
        rect.size = size
        if let center { rect.origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2) }
        clamp()
    }

    /// Sets the Image size field for one axis (pixels or percent); a locked ratio scales the other along.
    func setOutput(_ value: CGFloat, width: Bool) {
        let base = width ? rect.width * pixelScale : rect.height * pixelScale
        let scale = outputInPercent ? value / 100 : value / max(base, 1)
        guard scale > 0 else { return }
        let factor = scale / (width ? outputScaleX : outputScaleY)
        if lockOutputRatio { outputScaleX *= factor; outputScaleY *= factor }
        else if width { outputScaleX = scale } else { outputScaleY = scale }
    }

    func clamp() {
        rect = rect.standardized
        if ratioValue != nil {
            // Keep the ratio: shrink (or grow to the minimum) both sides by the same factor.
            let down = min(1, maxCrop / rect.width, maxCrop / rect.height)
            let up = max(1, 8 / rect.width, 8 / rect.height)
            let f = down < 1 ? down : up
            rect.size = CGSize(width: rect.width * f, height: rect.height * f)
        }
        rect.size.width = min(max(rect.width, 8), maxCrop)
        rect.size.height = min(max(rect.height, 8), maxCrop)
    }

    /// Renders the crop of `image` (pixels) at the Image size; whatever the frame covers past the screenshot is
    /// the fill.
    func render(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let out = outputPixels
        let w = Int(out.width), h = Int(out.height)
        guard let ctx = ImageProcessing.context(width: w, height: h, colorSpace: image.colorSpace) else { return nil }
        ctx.interpolationQuality = .high
        if let color = fillColor(for: image) { ctx.setFillColor(color); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        // Crop points → output pixels. CGContext is bottom-up; the crop rect is top-down.
        let sx = CGFloat(w) / rect.width, sy = CGFloat(h) / rect.height
        let drawn = CGRect(x: -rect.minX * sx, y: CGFloat(h) - (imageSize.height - rect.minY) * sy,
                           width: imageSize.width * sx, height: imageSize.height * sy)
        ctx.draw(image, in: drawn)
        return ctx.makeImage()
    }
}

/// Behind the scroll view while cropping: the fill (or the transparency grid) across the whole view, dimmed outside
/// the frame. It stays fixed to the screen, so scrolling and zooming only repaint one view-sized layer, and the fill
/// reaches as far as one can zoom out.
final class CropBackdropView: NSView {
    static let dim = NSColor.black.withAlphaComponent(0.55).cgColor
    let state: CropState
    weak var canvas: NSView?
    /// nil = transparent (the grid).
    var fill: CGColor? { didSet { needsDisplay = true } }

    init(state: CropState, canvas: NSView) {
        self.state = state
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func observe() {
        withObservationTracking { _ = state.rect } onChange: { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true; self?.observe() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let canvas else { return }
        if let fill {
            ctx.setFillColor(fill)
            ctx.fill(dirtyRect)
        } else {
            // The editor's grid (10pt cells on screen), anchored to this view, not to the canvas.
            Glint.BackgroundStyle.drawChecker(in: bounds, cell: 10, ctx: ctx)
        }
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addRect(convert(state.rect, from: canvas))
        ctx.addPath(dim)
        ctx.setFillColor(Self.dim)
        ctx.fillPath(using: .evenOdd)
    }
}

/// Overlay on the canvas while cropping: dims the screenshot outside the crop, draws the frame, thirds and handles.
/// It covers the whole room around the screenshot, so the handles can be grabbed anywhere.
final class CropOverlayView: NSView {
    let state: CropState
    var magnification: () -> CGFloat = { 1 }
    /// The frame moved or was resized (`dragging`: the mouse is still down).
    var onRectChange: ((_ dragging: Bool) -> Void)?
    /// A handle is being dragged: the point it sets and the pointer, both in screenshot points; nil = it ended.
    var onHandleDrag: ((_ anchor: CGPoint, _ pointer: CGPoint) -> Void)?
    var onHandleDragEnd: (() -> Void)?
    private enum Drag { case none, move(start: CGPoint, original: CGRect), edge(Set<Character>) }
    private var drag: Drag = .none

    init(state: CropState) {
        self.state = state
        super.init(frame: .zero)
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    private func observe() {
        withObservationTracking { _ = state.rect } onChange: { [weak self] in
            DispatchQueue.main.async { self?.needsDisplay = true; self?.window?.invalidateCursorRects(for: self!); self?.observe() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let m = magnification(), r = state.rect
        // Outside the screenshot the backdrop dims; here only the screenshot's part outside the frame.
        ctx.saveGState()
        ctx.clip(to: CGRect(origin: .zero, size: state.imageSize))
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addRect(r)
        ctx.addPath(dim)
        ctx.setFillColor(CropBackdropView.dim)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1 / m)
        ctx.stroke(r)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: r.minY)); ctx.addLine(to: CGPoint(x: x, y: r.maxY))
            ctx.move(to: CGPoint(x: r.minX, y: y)); ctx.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        ctx.strokePath()

        // Corner brackets and edge bars.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(4 / m)
        ctx.setLineCap(.square)
        let L = 18 / m, o = 2 / m
        for (cx, cy, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            ctx.move(to: CGPoint(x: cx - o * sx, y: cy + L * sy)); ctx.addLine(to: CGPoint(x: cx - o * sx, y: cy - o * sy))
            ctx.addLine(to: CGPoint(x: cx + L * sx, y: cy - o * sy))
        }
        let B = 10 / m
        ctx.move(to: CGPoint(x: r.midX - B, y: r.minY - o)); ctx.addLine(to: CGPoint(x: r.midX + B, y: r.minY - o))
        ctx.move(to: CGPoint(x: r.midX - B, y: r.maxY + o)); ctx.addLine(to: CGPoint(x: r.midX + B, y: r.maxY + o))
        ctx.move(to: CGPoint(x: r.minX - o, y: r.midY - B)); ctx.addLine(to: CGPoint(x: r.minX - o, y: r.midY + B))
        ctx.move(to: CGPoint(x: r.maxX + o, y: r.midY - B)); ctx.addLine(to: CGPoint(x: r.maxX + o, y: r.midY + B))
        ctx.strokePath()
    }

    /// Which edges a point grabs: "l", "r", "t", "b" combinations; empty = inside (move).
    private func edges(at p: CGPoint) -> Set<Character>? {
        let r = state.rect, tol = 9 / magnification()
        var e = Set<Character>()
        if abs(p.x - r.minX) < tol { e.insert("l") } else if abs(p.x - r.maxX) < tol { e.insert("r") }
        if abs(p.y - r.minY) < tol { e.insert("t") } else if abs(p.y - r.maxY) < tol { e.insert("b") }
        let inX = p.x > r.minX - tol && p.x < r.maxX + tol, inY = p.y > r.minY - tol && p.y < r.maxY + tol
        guard inX && inY else { return nil }
        return e
    }

    override func resetCursorRects() {
        let r = state.rect, t = 9 / magnification()
        guard r.width.isFinite, r.height.isFinite, t.isFinite else { return }
        // AppKit throws on empty or negative cursor rects (a tiny crop frame at a low zoom makes them).
        func add(_ rect: CGRect, _ cursor: NSCursor) {
            guard rect.width > 0, rect.height > 0 else { return }
            addCursorRect(rect, cursor: cursor)
        }
        add(r.insetBy(dx: t, dy: t), .openHand)
        // Edges: two-way arrows; corners: diagonal arrows toward the middle and outward.
        let edges: [(CGRect, NSCursor.FrameResizePosition)] = [
            (CGRect(x: r.minX - t, y: r.minY + t, width: t * 2, height: r.height - t * 2), .left),
            (CGRect(x: r.maxX - t, y: r.minY + t, width: t * 2, height: r.height - t * 2), .right),
            (CGRect(x: r.minX + t, y: r.minY - t, width: r.width - t * 2, height: t * 2), .top),
            (CGRect(x: r.minX + t, y: r.maxY - t, width: r.width - t * 2, height: t * 2), .bottom),
            (CGRect(x: r.minX - t, y: r.minY - t, width: t * 2, height: t * 2), .topLeft),
            (CGRect(x: r.maxX - t, y: r.minY - t, width: t * 2, height: t * 2), .topRight),
            (CGRect(x: r.minX - t, y: r.maxY - t, width: t * 2, height: t * 2), .bottomLeft),
            (CGRect(x: r.maxX - t, y: r.maxY - t, width: t * 2, height: t * 2), .bottomRight),
        ]
        for (rect, position) in edges {
            add(rect, NSCursor.frameResize(position: position, directions: .all))
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A click in the workspace ends editing in the toolbar fields, which applies what was typed (like Return).
        if let canvas = superview, window?.firstResponder !== canvas { window?.makeFirstResponder(canvas) }
        let p = convert(event.locationInWindow, from: nil)
        guard let e = edges(at: p) else { drag = .none; return }
        drag = e.isEmpty ? .move(start: p, original: state.rect) : .edge(e)
        if e.isEmpty { NSCursor.closedHand.set() } else { reportHandle(e, pointer: p) }
    }

    override func mouseDragged(with event: NSEvent) {
        if case .none = drag { return }
        var p = convert(event.locationInWindow, from: nil)
        // Dragging past the visible area scrolls it (the room grows as the frame goes); only then, as autoscroll
        // otherwise nudged the view on every drag.
        if !visibleRect.contains(p) { autoscroll(with: event) }
        p.x = p.x.rounded(); p.y = p.y.rounded()
        let snap = state.snapToEdges && !event.modifierFlags.contains(.command)
        let size = state.imageSize, threshold = 8 / magnification()
        // Soft snapping: within the threshold of one of the screenshot's edges a frame edge sits on it; dragging on
        // pulls it free again (no hard stop).
        func nearest(_ v: CGFloat, _ limit: CGFloat) -> CGFloat? {
            guard snap else { return nil }
            let d = [0 - v, limit - v].min { abs($0) < abs($1) }!
            return abs(d) < threshold ? d : nil
        }
        var r = state.rect
        switch drag {
        case .none: return
        case .move(let start, let original):
            r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            // Either side of the frame may snap; the closer one wins.
            let dx = [nearest(r.minX, size.width), nearest(r.maxX, size.width)].compactMap { $0 }.min { abs($0) < abs($1) }
            let dy = [nearest(r.minY, size.height), nearest(r.maxY, size.height)].compactMap { $0 }.min { abs($0) < abs($1) }
            r.origin.x += dx ?? 0
            r.origin.y += dy ?? 0
        case .edge(let e):
            let x = p.x + (nearest(p.x, size.width) ?? 0), y = p.y + (nearest(p.y, size.height) ?? 0)
            if e.contains("l") { r.size.width = r.maxX - x; r.origin.x = x }
            if e.contains("r") { r.size.width = x - r.minX }
            if e.contains("t") { r.size.height = r.maxY - y; r.origin.y = y }
            if e.contains("b") { r.size.height = y - r.minY }
            r = r.standardized
            if let ratio = state.ratioValue {
                // Keep the ratio: width leads for side/corner drags, height for top/bottom only.
                if e.contains("l") || e.contains("r") { let h = r.width / ratio; if e.contains("t") { r.origin.y = r.maxY - h }; r.size.height = h }
                else { let w = r.height * ratio; r.size.width = w }
            }
        }
        state.rect = r
        state.clamp()
        onRectChange?(true)
        if case .edge(let e) = drag { reportHandle(e, pointer: p) }
    }

    /// A corner is the point it sets; an edge the spot on it nearest the pointer.
    private func reportHandle(_ e: Set<Character>, pointer: CGPoint) {
        let r = state.rect
        let x = e.contains("l") ? r.minX : (e.contains("r") ? r.maxX : min(max(pointer.x, r.minX), r.maxX))
        let y = e.contains("t") ? r.minY : (e.contains("b") ? r.maxY : min(max(pointer.y, r.minY), r.maxY))
        onHandleDrag?(CGPoint(x: x, y: y), pointer)
    }

    override func mouseUp(with event: NSEvent) {
        let dragged: Bool = { if case .none = drag { false } else { true } }()
        drag = .none
        window?.invalidateCursorRects(for: self)
        onHandleDragEnd?()
        if dragged { onRectChange?(false) }
    }
}

/// The zoom lens while a crop handle is dragged: the pixels around the point the handle sets, 8× and unsmoothed, with
/// the frame on top and the point's position in pixels.
final class CropLensView: NSView {
    static let side: CGFloat = 148
    private static let zoom: CGFloat = 8
    private static let labelFont: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white]

    private let state: CropState
    /// The flattened screenshot, in pixels.
    var image: CGImage?
    var anchor: CGPoint = .zero { didSet { needsDisplay = true } }

    init(state: CropState) {
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        wantsLayer = true
        alphaValue = 0
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outline = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 14, cornerHeight: 14, transform: nil)
        let zoom = Self.zoom, scale = state.pixelScale
        // The lens's top-left corner in pixels (the anchor stays in its middle).
        let origin = CGPoint(x: anchor.x * scale - bounds.width / 2 / zoom, y: anchor.y * scale - bounds.height / 2 / zoom)
        func lens(_ px: CGPoint) -> CGPoint { CGPoint(x: (px.x - origin.x) * zoom, y: (px.y - origin.y) * zoom) }

        ctx.saveGState()
        ctx.addPath(outline)
        ctx.clip()
        // Past the screenshot: what the crop would fill it with.
        if let image, let fill = state.fillColor(for: image) {
            ctx.setFillColor(fill)
            ctx.fill(bounds)
        } else {
            Glint.BackgroundStyle.drawChecker(in: bounds, cell: Self.zoom, ctx: ctx)
        }
        if let image {
            let wanted = CGRect(x: floor(origin.x), y: floor(origin.y), width: ceil(bounds.width / zoom) + 1, height: ceil(bounds.height / zoom) + 1)
            let shown = wanted.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if !shown.isEmpty, let piece = image.cropping(to: shown) {
                let at = lens(shown.origin)
                NSImage(cgImage: piece, size: .zero).draw(in: CGRect(x: at.x, y: at.y, width: shown.width * zoom, height: shown.height * zoom),
                                                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                                                          hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
        }
        // What the crop cuts off is dimmed, and the frame on top.
        let r = state.rect
        let a = lens(CGPoint(x: r.minX * scale, y: r.minY * scale)), b = lens(CGPoint(x: r.maxX * scale, y: r.maxY * scale))
        let frame = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addRect(frame)
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(frame)
        // Where the point is.
        let text = "\(Int((anchor.x * scale).rounded())), \(Int((anchor.y * scale).rounded()))" as NSString
        let size = text.size(withAttributes: Self.labelFont)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 6, y: bounds.maxY - size.height - 10, width: size.width + 12, height: size.height + 3)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fillPath()
        text.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 1.5), withAttributes: Self.labelFont)
        ctx.restoreGState()

        ctx.addPath(outline)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
    }
}
