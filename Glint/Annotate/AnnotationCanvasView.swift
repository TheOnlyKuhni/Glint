import AppKit
import Carbon.HIToolbox

/// The editable screenshot. Coordinates are document points with a top-left origin.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let doc: AnnotationDocument
    var onToolShortcut: ((AnnotateTool) -> Void)?
    var onCommand: ((String) -> Void)?  // "close", "background", "crop"
    var onGeometryChange: (() -> Void)?

    private enum Handle { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end, bend }
    private enum DragState {
        case none
        case creating(UUID)
        case moving(UUID, last: CGPoint)
        case resizing(UUID, Handle)
    }

    private var dragState: DragState = .none
    private var stateBeforeDrag: [Annotation] = []
    private(set) var textView: NSTextView?

    init(document: AnnotationDocument) {
        doc = document
        super.init(frame: CGRect(origin: .zero, size: document.imageSize))
        wantsLayer = true
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -4)
        self.shadow = shadow
        canvasShadow = shadow
        observeDocument()
        updateGeometry()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Canvas = screenshot + background. Bounds are offset so drawing and mouse coordinates stay
    /// relative to the screenshot's top-left, whatever padding the background adds.
    /// Background as of the last geometry update. Drawing uses this snapshot so a frame never mixes a new layout
    /// with the old frame/zoom (that mismatch was the jitter while dragging padding/inset).
    private var displayedBackground: Glint.BackgroundStyle?

    /// Applies the document's layout now (instead of on the next run loop pass), so the caller can keep the view in
    /// place when the canvas grows on the left/top.
    func syncGeometry() { updateGeometry() }

    private var canvasShadow: NSShadow?

    /// While cropping the canvas is only the room around the screenshot: no shadow and no transparency grid (the
    /// crop backdrop behind the scroll view shows the fill, fixed to the screen, so zooming redraws nothing big).
    var isCropRoom = false {
        didSet {
            shadow = isCropRoom ? nil : canvasShadow
            needsDisplay = true
        }
    }

    private func updateGeometry() {
        displayedBackground = doc.displayBackground
        let layout = doc.layout
        setFrameSize(layout.canvasSize)
        bounds = CGRect(origin: CGPoint(x: -layout.imageOrigin.x, y: -layout.imageOrigin.y), size: layout.canvasSize)
        updateShadowPath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateScreenshotLayer()
        CATransaction.commit()
        needsDisplay = true
    }

    /// An explicit shadow outline: without it Core Animation re-renders the drop shadow offscreen from the
    /// view's pixels on every size change, which made padding/inset sliders janky.
    private func updateShadowPath() {
        guard let layer else { return }
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
    }

    override func layout() {
        super.layout()
        updateShadowPath()
    }

    // MARK: Space-bar panning

    private(set) var spaceHeld = false
    private var isPanning = false

    func beginPanMode() {
        spaceHeld = true
        NSCursor.openHand.set()
    }

    func endPanMode() {
        spaceHeld = false
        isPanning = false
        window?.invalidateCursorRects(for: self)
        toolCursor.set()
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space, spaceHeld { endPanMode(); return }
        super.keyUp(with: event)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    private func observeDocument() {
        withObservationTracking {
            _ = doc.annotations; _ = doc.selectedID; _ = doc.editingTextID; _ = doc.tool; _ = doc.background; _ = doc.counter; _ = doc.imageSize; _ = doc.expansion; _ = doc.baseImage; _ = doc.expandsCanvas
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                let layout = self.doc.layout
                self.displayedBackground = self.doc.displayBackground
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.updateScreenshotLayer()
                CATransaction.commit()
                if self.frame.size != layout.canvasSize || self.bounds.origin != CGPoint(x: -layout.imageOrigin.x, y: -layout.imageOrigin.y) {
                    // Resize and refit in one transaction so no frame shows the old zoom with the new size.
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.updateGeometry()
                    self.onGeometryChange?()
                    CATransaction.commit()
                    self.enclosingScrollView?.displayIfNeeded()
                }
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
                self.observeDocument()
            }
        }
    }

    // MARK: Drawing

    // The canvas is three layers: this view draws the backdrop (cheap fills), `screenshotView` shows the screenshot
    // as a GPU texture (moving/zooming it never re-rasterizes it), and `overlay` draws redactions, annotations and
    // the selection. Background sliders therefore only move layers, which keeps them smooth.
    private lazy var screenshotView = ScreenshotLayerView(image: doc.baseImage)
    private lazy var overlay = CanvasOverlayView(canvas: self)

    override var needsDisplay: Bool {
        didSet { if needsDisplay { overlay.needsDisplay = true } }
    }

    private func makeRenderer() -> AnnotationRenderer {
        let needsEffects = doc.annotations.contains { $0.kind == .redact }
        var renderer = AnnotationRenderer(baseImage: doc.baseImage, imageSize: doc.imageSize,
                                          effects: needsEffects ? doc.effects : nil)
        renderer.counter = doc.counter
        renderer.images = doc.images
        renderer.deviceScale = (window?.backingScaleFactor ?? 2) * magnification
        renderer.background = displayedBackground
        renderer.transparencyGridCell = isCropRoom ? nil : 10 / max(magnification, 0.01)
        return renderer
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        makeRenderer().draw(doc.annotations, in: ctx, editingTextID: doc.editingTextID, parts: .backdrop)
    }

    func drawOverlay(in ctx: CGContext) {
        makeRenderer().draw(doc.annotations, in: ctx, editingTextID: doc.editingTextID, parts: .overlay)
        if let selected = doc.selected, doc.editingTextID == nil { drawSelection(for: selected, ctx: ctx) }
    }

    /// Positions the screenshot layer and its corner mask for the current layout.
    private func updateScreenshotLayer() {
        if screenshotView.superview == nil {
            addSubview(screenshotView, positioned: .below, relativeTo: nil)
            addSubview(overlay, positioned: .above, relativeTo: screenshotView)
        }
        screenshotView.image = doc.baseImage
        screenshotView.frame = CGRect(origin: .zero, size: doc.imageSize)
        let ins = (displayedBackground?.inset ?? 0) * Glint.BackgroundStyle.maxInset
        let clip: CGPath? = displayedBackground.flatMap { bg -> CGPath? in
            let radii = bg.cornerRadii(imageSize: doc.imageSize)
            guard radii.contains(where: { $0 > 0 }) else { return nil }
            // Card path in the screenshot's own (y-down) coordinates.
            return Glint.BackgroundStyle.cornerPath(CGRect(origin: .zero, size: doc.imageSize).insetBy(dx: -ins, dy: -ins), radii: radii)
        }
        screenshotView.setMask(clip)
        overlay.frame = bounds
        // Grow canvas off: whatever reaches past the canvas is cut off, here as in the export.
        overlay.clipsToBounds = !doc.expandsCanvas
        overlay.bounds = bounds
    }

    private func drawSelection(for a: Annotation, ctx: CGContext) {
        let m = magnification
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.2 / m)
        ctx.setLineDash(phase: 0, lengths: [5 / m, 4 / m])
        if case .counter = a.kind {
            // Counters get a solid accent ring.
            let b = bounds(of: a).insetBy(dx: -3.5 / m, dy: -3.5 / m)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(2.5 / m)
            ctx.addPath(CGPath(roundedRect: b, cornerWidth: b.height / 2, cornerHeight: b.height / 2, transform: nil))
            ctx.strokePath()
        } else if a.kind == .draw || a.kind == .highlighter {
            // A selected freehand stroke turns blue, slightly wider than the stroke.
            let width = a.kind == .highlighter ? AnnotationRenderer.highlighterWidth(of: a) : a.lineWidth
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setStrokeColor(NSColor(srgbRed: 0x65 / 255, green: 0xA7 / 255, blue: 0xF8 / 255, alpha: a.kind == .highlighter ? 0.55 : 1).cgColor)
            ctx.setLineWidth(width + 1 / m)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(AnnotationRenderer.smoothPath(a.points))
            ctx.strokePath()
        } else if case .line = a.kind {} else if case .arrow = a.kind {} else {
            ctx.stroke(bounds(of: a).insetBy(dx: -5 / m, dy: -5 / m))
        }
        ctx.setLineDash(phase: 0, lengths: [])
        for (_, point) in handles(for: a) {
            let r = 4.5 / m
            let c = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fillEllipse(in: c)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5 / m)
            ctx.strokeEllipse(in: c)
        }
        ctx.restoreGState()
    }

    // MARK: Geometry

    private func bounds(of a: Annotation) -> CGRect {
        switch a.kind {
        case .text, .counter, .draw, .highlighter: doc.bounds(of: a)
        default: a.rect
        }
    }

    private func handles(for a: Annotation) -> [(Handle, CGPoint)] {
        switch a.kind {
        case .arrow where a.isBendable:
            return [(.start, a.start), (.bend, a.bendPoint), (.end, a.end)]
        case .line, .arrow:
            return [(.start, a.start), (.end, a.end)]
        case .image:
            // Added images resize from their corners only, keeping their proportions.
            let r = a.rect
            return [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.topRight, CGPoint(x: r.maxX, y: r.minY)),
                    (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottomLeft, CGPoint(x: r.minX, y: r.maxY))]
        case _ where a.isRectLike:
            let r = a.rect
            return [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
                    (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
                    (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                    (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
        default:
            return []
        }
    }

    private func hitTestAnnotation(_ p: CGPoint) -> Annotation? {
        let tol = 5 / magnification
        for a in doc.annotations.reversed() {
            switch a.kind {
            case .arrow where a.isBendable && a.control != nil:
                let pts = a.curvePoints()
                for (q1, q2) in zip(pts, pts.dropFirst()) where distance(p, toSegment: q1, q2) <= a.lineWidth / 2 + tol { return a }
            case .line, .arrow:
                if distance(p, toSegment: a.start, a.end) <= a.lineWidth / 2 + tol { return a }
            case .draw, .highlighter:
                let w = a.kind == .highlighter ? AnnotationRenderer.highlighterWidth(of: a) : a.lineWidth
                for (q1, q2) in zip(a.points, a.points.dropFirst()) where distance(p, toSegment: q1, q2) <= w / 2 + tol { return a }
                if a.points.count == 1, hypot(p.x - a.points[0].x, p.y - a.points[0].y) <= w / 2 + tol { return a }
            default:
                if bounds(of: a).insetBy(dx: -tol, dy: -tol).contains(p) { return a }
            }
        }
        return nil
    }

    private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Mouse

    /// Last pointer position (document points) used for the preview cursor.
    private var hoverPoint: CGPoint?
    private var isDrawing: Bool { if case .creating = dragState { true } else { false } }

    /// Preview cursors: Draw shows a circle as big as the pen, Highlighter a marker tip as big as
    /// the band it will paint (shrinking to the text line when hovering text). Others: crosshair / arrow.
    private var toolCursor: NSCursor {
        // Cropping: the tool rests until Crop & Resize ends.
        if doc.isCropping { return .arrow }
        let zoom = magnification
        switch doc.tool {
        case .select: return .arrow
        case .draw:
            let width = max(2, AnnotationStyle.thicknesses[doc.thickness] * 0.75)
            return PreviewCursor.circle(diameter: width * zoom)
        case .highlighter:
            if let p = hoverPoint, let line = doc.textLine(at: p) {
                return PreviewCursor.marker(height: (line.height + 4) * zoom)
            }
            return PreviewCursor.marker(height: AnnotationRenderer.highlighterWidth(AnnotationStyle.thicknesses[doc.thickness]) * zoom)
        default: return .crosshair
        }
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: toolCursor)
    }

    // Re-assert the tool cursor: a removed text view could otherwise leave the I-beam behind.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { toolCursor.set() }

    override func mouseMoved(with event: NSEvent) {
        guard textView == nil, !doc.isCropping else { return }
        hoverPoint = convert(event.locationInWindow, from: nil)
        if spaceHeld { NSCursor.openHand.set(); return }
        // While a stroke is being drawn the cursor keeps its size (the stroke is already decided).
        if !isDrawing { toolCursor.set() }
    }

    override func mouseDown(with event: NSEvent) {
        if spaceHeld {
            isPanning = true
            NSCursor.closedHand.set()
            return
        }
        // Cropping: the crop frame takes the clicks; the tool doesn't draw meanwhile.
        if doc.isCropping { window?.makeFirstResponder(self); return }
        let p = convert(event.locationInWindow, from: nil)
        if textView != nil { endTextEditing() }
        window?.makeFirstResponder(self)
        stateBeforeDrag = doc.annotations
        doc.isInteracting = true
        // "Inverse arrow direction" puts the head where the drag started; ⌥ flips the setting for this arrow.
        arrowAnchor = p

        // Draw/Highlighter with a locked canvas always draw, even starting on an object;
        // unlocked, they can grab and move existing objects.
        let drawsOnly = (doc.tool == .draw || doc.tool == .highlighter) && !doc.canvasUnlocked
        if drawsOnly { doc.selectedID = nil }

        // Handles of the current selection.
        if !drawsOnly, let selected = doc.selected {
            let r = 7 / magnification
            if let (handle, _) = handles(for: selected).first(where: { hypot($0.1.x - p.x, $0.1.y - p.y) <= r }) {
                if selected.isRectLike { normalize(selected.id) }
                dragState = .resizing(selected.id, handle)
                return
            }
        }

        if !drawsOnly, let hit = hitTestAnnotation(p) {
            doc.selectedID = hit.id
            if event.clickCount == 2, case .text = hit.kind {
                beginTextEditing(hit.id)
                return
            }
            dragState = .moving(hit.id, last: p)
            return
        }

        doc.selectedID = nil
        let style = (color: doc.color, thickness: doc.thickness)
        switch doc.tool {
        case .select:
            dragState = .none
        case .counter:
            // Placed counters stay unselected (click one to select it).
            let a = Annotation(kind: .counter(doc.nextCounter), start: p, end: p, color: style.color, thickness: style.thickness)
            doc.annotations.append(a)
            dragState = .moving(a.id, last: p)
        case .text:
            var a = Annotation(kind: .text(""), start: p, end: p, color: style.color, thickness: style.thickness, fontSize: doc.fontSize)
            a.variant = doc.textStyle.rawValue
            a.start.y -= doc.fontSize * 0.62
            doc.annotations.append(a)
            doc.selectedID = a.id
            beginTextEditing(a.id)
            dragState = .none
        case .draw, .highlighter:
            var a = Annotation(kind: doc.tool == .draw ? .draw : .highlighter, start: p, end: p, points: [p],
                               color: style.color, thickness: style.thickness)
            // Starting on a line of text: snap to it.
            if doc.tool == .highlighter, let line = doc.textLine(at: p) {
                a.variant = 1
                a.amount = line.height + 4
                a.points = [CGPoint(x: p.x, y: line.midY)]
            }
            doc.annotations.append(a)
            dragState = .creating(a.id)
        default:
            let kind: Annotation.Kind = switch doc.tool {
            case .rectangle: .rectangle
            case .filledRectangle: .filledRectangle
            case .ellipse: .ellipse
            case .line: .line
            case .arrow: .arrow
            case .redact: .redact
            default: .spotlight
            }
            var a = Annotation(kind: kind, start: p, end: p, color: style.color, thickness: style.thickness)
            switch kind {
            case .redact: a.variant = doc.redactMode.rawValue; a.amount = doc.redactAmount
            case .spotlight: a.variant = doc.spotlightShape.rawValue; a.amount = doc.spotlightAmount
            case .arrow: a.variant = doc.arrowStyle.rawValue
            default: break
            }
            doc.annotations.append(a)
            dragState = .creating(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning, let clip = enclosingScrollView?.contentView {
            // Move the view with the hand (works whenever the image is larger than the window).
            let m = magnification
            var origin = clip.bounds.origin
            origin.x -= event.deltaX / m
            origin.y -= event.deltaY / m
            clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)
        switch dragState {
        case .none:
            break
        case .creating(let id):
            update(id) { a in
                switch a.kind {
                case .highlighter where a.variant == 1:
                    a.points = [a.points[0], CGPoint(x: p.x, y: a.points[0].y)]
                case .draw, .highlighter:
                    if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) > 1.5 / self.magnification { a.points.append(p) }
                case .arrow:
                    self.lastDragPoint = p
                    self.placeArrow(&a, tip: p, flags: event.modifierFlags)
                case .line:
                    a.end = shift ? Self.snapAngle(from: a.start, to: p) : p
                default:
                    a.end = shift ? Self.square(from: a.start, to: p) : p
                }
            }
        case .moving(let id, let last):
            update(id) { $0.offset(by: CGVector(dx: p.x - last.x, dy: p.y - last.y)) }
            dragState = .moving(id, last: p)
        case .resizing(let id, let handle):
            update(id) { a in
                switch handle {
                case .start: a.start = shift ? Self.snapAngle(from: a.end, to: p) : p
                case .end: a.end = shift ? Self.snapAngle(from: a.start, to: p) : p
                case .topLeft: a.start = p
                case .bottomRight: a.end = p
                case .topRight: a.end.x = p.x; a.start.y = p.y
                case .bottomLeft: a.start.x = p.x; a.end.y = p.y
                case .top: a.start.y = p.y
                case .bottom: a.end.y = p.y
                case .left: a.start.x = p.x
                case .right: a.end.x = p.x
                case .bend: a.control = p
                }
                if case .image(let key) = a.kind, let image = self.doc.images[key] { Self.keepAspect(&a, image: image, handle: handle) }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            if spaceHeld { NSCursor.openHand.set() }
            return
        }
        if case .creating(let id) = dragState, let a = doc.annotations.first(where: { $0.id == id }) {
            let tooSmall: Bool = switch a.kind {
            case .draw, .highlighter: false
            case .line, .arrow: hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 4
            default: a.rect.width < 4 || a.rect.height < 4
            }
            // Freehand strokes stay unselected after drawing.
            let freehand = a.kind == .draw || a.kind == .highlighter
            if tooSmall { doc.annotations.removeAll { $0.id == id } } else if !freehand { doc.selectedID = id }
        }
        if case .resizing(let id, _) = dragState { normalize(id) }
        dragState = .none
        lastDragPoint = nil
        if doc.annotations != stateBeforeDrag { registerUndo(from: stateBeforeDrag, name: "Edit") }
        doc.isInteracting = false
    }

    /// Where the current arrow drag started.
    private var arrowAnchor: CGPoint = .zero
    private var lastDragPoint: CGPoint?

    /// Draws the arrow being created from the drag start to the pointer. "Inverse arrow direction" puts the head at
    /// the start; holding ⌥ flips that, live, as often as it's pressed or released during the drag.
    private func placeArrow(_ a: inout Annotation, tip p: CGPoint, flags: NSEvent.ModifierFlags) {
        let tip = flags.contains(.shift) ? Self.snapAngle(from: arrowAnchor, to: p) : p
        let inverted = Defaults[Prefs.annotateInverseArrow] != flags.contains(.option)
        (a.start, a.end) = inverted ? (tip, arrowAnchor) : (arrowAnchor, tip)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard case .creating(let id) = dragState, let p = lastDragPoint,
              doc.annotations.first(where: { $0.id == id })?.kind == .arrow else { return }
        update(id) { placeArrow(&$0, tip: p, flags: event.modifierFlags) }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard let a = hitTestAnnotation(p) else { return nil }
        endTextEditing()
        doc.selectedID = a.id
        let menu = NSMenu()
        if case .arrow = a.kind {
            let flip = NSMenuItem(title: "Flip Arrow", action: #selector(flipArrow), keyEquivalent: "")
            flip.target = self
            menu.addItem(flip)
            menu.addItem(.separator())
        }
        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(duplicateSelection), keyEquivalent: "")
        duplicate.target = self
        menu.addItem(duplicate)
        let delete = NSMenuItem(title: "Delete", action: #selector(deleteSelection), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        return menu
    }

    /// Swaps the arrow's head and tail (a bend stays where it is).
    @objc private func flipArrow() {
        guard let id = doc.selectedID else { return }
        doc.checkpoint("Flip Arrow")
        update(id) { swap(&$0.start, &$0.end) }
    }

    @objc private func duplicateSelection() { doc.duplicateSelected() }
    @objc private func deleteSelection() { doc.deleteSelected() }

    private func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let i = doc.annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&doc.annotations[i])
    }

    /// Stores rect-like shapes as top-left/bottom-right so handle math stays simple.
    private func normalize(_ id: UUID) {
        update(id) { a in
            guard a.isRectLike else { return }
            let r = a.rect
            a.start = CGPoint(x: r.minX, y: r.minY)
            a.end = CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func registerUndo(from previous: [Annotation], name: String) {
        let current = doc.annotations
        doc.annotations = previous
        doc.checkpoint(name)
        doc.annotations = current
    }

    /// Corner resizing of an added image: the dragged corner follows the width, the opposite corner stays put.
    private static func keepAspect(_ a: inout Annotation, image: CGImage, handle: Handle) {
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let width = max(abs(a.end.x - a.start.x), 8)
        let height = width / aspect
        switch handle {
        case .topLeft, .topRight: a.start.y = a.end.y - height * (a.end.y >= a.start.y ? 1 : -1)
        case .bottomLeft, .bottomRight: a.end.y = a.start.y + height * (a.end.y >= a.start.y ? 1 : -1)
        default: break
        }
    }

    private static func square(from s: CGPoint, to p: CGPoint) -> CGPoint {
        let side = max(abs(p.x - s.x), abs(p.y - s.y))
        return CGPoint(x: s.x + (p.x >= s.x ? side : -side), y: s.y + (p.y >= s.y ? side : -side))
    }

    private static func snapAngle(from s: CGPoint, to p: CGPoint) -> CGPoint {
        let angle = atan2(p.y - s.y, p.x - s.x)
        let snapped = (angle / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(p.x - s.x, p.y - s.y)
        return CGPoint(x: s.x + cos(snapped) * len, y: s.y + sin(snapped) * len)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if doc.isCropping {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: onCommand?("applyCrop"); return
            case kVK_Escape: onCommand?("cancelCrop"); return
            default: break
            }
        }
        // Hold Space to pan the zoomed view with the mouse.
        if Int(event.keyCode) == kVK_Space {
            if !event.isARepeat { beginPanMode() }
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            doc.deleteSelected()
        case kVK_Escape:
            if doc.selectedID != nil { doc.selectedID = nil } else { onCommand?("close") }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            nudge(keyCode: Int(event.keyCode), step: flags.contains(.shift) ? 10 : 1)
        default:
            if flags == .command, chars == "0" {
                onCommand?("zoom100")
            } else if flags == .command, chars == "9" {
                onCommand?("zoomFit")
            } else if flags == .command, chars == "+" || chars == "=" {
                onCommand?("zoomIn")
            } else if flags == .command, chars == "-" {
                onCommand?("zoomOut")
            } else if flags == .command, chars == "d" {
                doc.duplicateSelected()
            } else if flags.isEmpty, chars == "b" {
                onCommand?("background")
            } else if flags.isEmpty, chars == "k" {
                onCommand?("crop")
            } else if flags.isEmpty, let tool = AnnotateTool.allCases.first(where: { $0.key == chars }) {
                onToolShortcut?(tool)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func nudge(keyCode: Int, step: CGFloat) {
        guard let id = doc.selectedID else { return }
        doc.checkpoint("Move")
        let d: CGVector = switch keyCode {
        case kVK_LeftArrow: CGVector(dx: -step, dy: 0)
        case kVK_RightArrow: CGVector(dx: step, dy: 0)
        case kVK_UpArrow: CGVector(dx: 0, dy: -step)
        default: CGVector(dx: 0, dy: step)
        }
        update(id) { $0.offset(by: d) }
    }

    // MARK: Text editing

    func beginTextEditing(_ id: UUID) {
        guard let a = doc.annotations.first(where: { $0.id == id }), case .text(let string) = a.kind else { return }
        doc.editingTextID = id
        let style = TextStyle(rawValue: a.variant) ?? .standard
        let pad = style.hasBox ? AnnotationRenderer.boxPadding(a.fontSize) : .zero
        let tv = NSTextView(frame: CGRect(origin: CGPoint(x: a.start.x + pad.width, y: a.start.y + pad.height),
                                          size: AnnotationRenderer.styledTextSize(string, size: a.fontSize, style: .standard)))
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.size = CGSize(width: 10_000, height: 10_000)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        applyEditingStyle(to: tv, annotation: a)
        tv.string = string
        tv.delegate = self
        tv.allowsUndo = true
        addSubview(tv)
        textView = tv
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = doc.editingTextID else { return }
        update(id) { $0.kind = .text(tv.string) }
        if let a = doc.annotations.first(where: { $0.id == id }) {
            tv.setFrameSize(Self.editorSize(tv.string, annotation: a))
            needsDisplay = true
        }
    }

    private static func editorSize(_ string: String, annotation a: Annotation) -> CGSize {
        let style = TextStyle(rawValue: a.variant) ?? .standard
        let s = (string.isEmpty ? " " : string) as NSString
        let r = s.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
                               attributes: [.font: style.font(size: a.fontSize)])
        return CGSize(width: ceil(r.width) + 2, height: ceil(r.height))
    }

    private func applyEditingStyle(to tv: NSTextView, annotation a: Annotation) {
        let style = TextStyle(rawValue: a.variant) ?? .standard
        let textColor: NSColor = style.hasBox ? (a.color.prefersWhiteText ? .white : .black) : a.color.nsColor
        let font = style.font(size: a.fontSize)
        tv.font = font
        tv.textColor = textColor
        tv.insertionPointColor = textColor
        tv.typingAttributes = [.font: font, .foregroundColor: textColor]
        let pad = style.hasBox ? AnnotationRenderer.boxPadding(a.fontSize) : .zero
        tv.setFrameOrigin(CGPoint(x: a.start.x + pad.width, y: a.start.y + pad.height))
        tv.setFrameSize(Self.editorSize(tv.string, annotation: a))
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    func endTextEditing() {
        guard let tv = textView, let id = doc.editingTextID else { return }
        tv.removeFromSuperview()
        textView = nil
        doc.editingTextID = nil
        if case .text(let s)? = doc.annotations.first(where: { $0.id == id })?.kind,
           s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.annotations.removeAll { $0.id == id }
            doc.selectedID = nil
        }
        if doc.annotations != stateBeforeDrag { registerUndo(from: stateBeforeDrag, name: "Text") }
        window?.makeFirstResponder(self)
    }

    /// Restyles the text being edited (or the selection) after a toolbar change.
    func styleChanged() {
        if let tv = textView, let id = doc.editingTextID {
            update(id) { a in a.color = doc.color; a.fontSize = doc.fontSize; a.variant = doc.textStyle.rawValue }
            if let a = doc.annotations.first(where: { $0.id == id }) { applyEditingStyle(to: tv, annotation: a) }
            needsDisplay = true
        } else if doc.selected == nil, doc.tool == .counter {
            // Counter tool without a selection: the color goes to every counter.
            doc.recolorCounters()
        } else {
            doc.applyStyleToSelection()
        }
    }
}

/// Shows the screenshot as layer contents (a GPU texture): scaling and moving it is free.
final class ScreenshotLayerView: NSView {
    var image: CGImage { didSet { if image !== oldValue { layer?.contents = image } } }
    private let maskLayer = CAShapeLayer()

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Corner clip; the path is y-down in this view's coordinates.
    func setMask(_ path: CGPath?) {
        guard let path, let layer else { layer?.mask = nil; return }
        // A flipped view's layer interprets the mask path y-down, matching the path.
        maskLayer.path = path
        maskLayer.frame = layer.bounds
        layer.mask = maskLayer
    }
}

/// Transparent view above the screenshot that draws redactions, annotations and the selection.
final class CanvasOverlayView: NSView {
    private unowned let canvas: AnnotationCanvasView
    init(canvas: AnnotationCanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        canvas.drawOverlay(in: ctx)
    }
}
