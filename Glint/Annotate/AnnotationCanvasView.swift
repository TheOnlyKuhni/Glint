import AppKit
import Carbon.HIToolbox

/// The editable screenshot. Coordinates are document points with a top-left origin.
final class AnnotationCanvasView: NSView, NSTextViewDelegate {
    let doc: AnnotationDocument
    var onToolShortcut: ((AnnotateTool) -> Void)?
    var onCommand: ((String) -> Void)?  // "close", "background", "crop"
    var onGeometryChange: (() -> Void)?

    private enum Handle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, start, end, bend
        /// A magnifier's bubble (or in-place lens) corners.
        case lensTopLeft, lensTopRight, lensBottomRight, lensBottomLeft
    }
    /// Moving a callout magnifier: its area or its bubble (the other part stays).
    private enum MagnifierPart { case area, bubble }
    private var movingPart: MagnifierPart?
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
        } else if case .line = a.kind {} else if case .arrow = a.kind {} else if a.kind == .magnifier {
            if a.magnifierStyle == .callout { ctx.stroke(a.rect.insetBy(dx: -5 / m, dy: -5 / m)) }
            ctx.stroke(a.bubbleRect.insetBy(dx: -5 / m, dy: -5 / m))
        } else {
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
        case .magnifier:
            let b = a.bubbleRect
            let lens: [(Handle, CGPoint)] = [(.lensTopLeft, CGPoint(x: b.minX, y: b.minY)), (.lensTopRight, CGPoint(x: b.maxX, y: b.minY)),
                                              (.lensBottomRight, CGPoint(x: b.maxX, y: b.maxY)), (.lensBottomLeft, CGPoint(x: b.minX, y: b.maxY))]
            guard a.magnifierStyle == .callout else { return lens }
            let r = a.rect
            return lens + [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
                           (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
                           (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
                           (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
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
            case .magnifier:
                if magnifierPart(a, at: p) != nil { return a }
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

    /// Which part of a magnifier is under `p`: its bubble (or lens), or a callout's area.
    private func magnifierPart(_ a: Annotation, at p: CGPoint) -> MagnifierPart? {
        let tol = 5 / magnification
        if a.bubbleRect.insetBy(dx: -tol, dy: -tol).contains(p) { return .bubble }
        if a.magnifierStyle == .callout, a.rect.insetBy(dx: -tol, dy: -tol).contains(p) { return .area }
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

    /// The tool in use: outside Annotate mode the tools rest and the canvas works like Select.
    private var tool: AnnotateTool { doc.toolsResting ? .select : doc.tool }

    /// Last pointer position (document points) used for the preview cursor.
    private var hoverPoint: CGPoint?
    private var isDrawing: Bool { if case .creating = dragState { true } else { false } }

    /// Preview cursors: Draw shows a circle as big as the pen, Highlighter a marker tip as big as
    /// the band it will paint (shrinking to the text line when hovering text). Others: crosshair / arrow.
    private var toolCursor: NSCursor {
        // Cropping: the tool rests until Crop & Resize ends.
        if doc.isCropping { return .arrow }
        let zoom = magnification
        switch tool {
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

    /// Scrolling over the selected magnifier changes its zoom (one undo step per gesture).
    private var lastMagnifierScroll: TimeInterval = 0
    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let a = doc.selected, a.kind == .magnifier, magnifierPart(a, at: p) != nil,
              !event.modifierFlags.contains(.command), abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
        else { super.scrollWheel(with: event); return }
        if event.phase.contains(.began) || event.timestamp - lastMagnifierScroll > 0.6 { doc.checkpoint("Zoom") }
        lastMagnifierScroll = event.timestamp
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        let zoom = MagnifierZoom.clamp(a.magnification * exp(delta * 0.01))
        doc.magnifierZoom = zoom
        update(a.id) { m in
            if m.magnifierStyle == .callout { m.magCenter = m.magCenter ?? CGPoint(x: m.bubbleRect.midX, y: m.bubbleRect.midY) }
            m.magZoom = zoom
        }
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

        // With the canvas locked (the default) every drawing tool draws, even starting on an object;
        // unlocked, they can grab and move existing objects.
        let drawsOnly = tool != .select && !doc.canvasUnlocked
        let flags = event.modifierFlags

        // Handles of the current selection resize it with any tool, locked or not (they're on screen to be used).
        if let selected = doc.selected {
            let r = 7 / magnification
            if let (handle, _) = handles(for: selected).first(where: { hypot($0.1.x - p.x, $0.1.y - p.y) <= r }) {
                if selected.isRectLike { normalize(selected.id) }
                let box = doc.selected?.rect ?? selected.rect
                resizeAspect = box.width / max(box.height, 1)
                dragState = .resizing(selected.id, handle)
                return
            }
        }
        if drawsOnly { doc.selectedID = nil }

        // Text tool: a double-click on a text edits it, also with the canvas locked (the first click's empty text is
        // gone again by now).
        if tool == .text, event.clickCount == 2, let hit = hitTestAnnotation(p), case .text = hit.kind {
            doc.selectedID = hit.id
            beginTextEditing(hit.id)
            return
        }

        if !drawsOnly, var hit = hitTestAnnotation(p) {
            if event.clickCount == 2, case .text = hit.kind {
                doc.selectedID = hit.id
                beginTextEditing(hit.id)
                return
            }
            // ⌥-drag moves a copy and leaves the original in place.
            if flags.contains(.option) {
                var copy = hit.duplicated()
                if case .counter = copy.kind { copy.kind = .counter(doc.nextCounter) }
                doc.annotations.append(copy)
                hit = copy
            }
            doc.selectedID = hit.id
            movingPart = hit.kind == .magnifier && hit.magnifierStyle == .callout && !flags.contains(.option) ? magnifierPart(hit, at: p) : nil
            beginMove(hit.id, at: p)
            return
        }

        doc.selectedID = nil
        let style = (color: doc.color, thickness: doc.thickness)
        switch tool {
        case .select:
            dragState = .none
        case .emoji:
            // An emoji is an image object: it can be moved and resized like an added screenshot.
            guard let image = EmojiImage.render(doc.emoji, points: doc.emojiSize) else { dragState = .none; break }
            let lastEmoji = doc.annotations.last { a in if case .image(let key) = a.kind { doc.emojiKeys.contains(key) } else { false } }
            let a = doc.stampImage(image, size: CGSize(width: doc.emojiSize, height: doc.emojiSize), center: p)
            beginPlacing(a.id, at: p, alignedWith: lastEmoji.map { bounds(of: $0) }, flags: flags)
        case .counter:
            let lastCounter = doc.annotations.last { a in if case .counter = a.kind { true } else { false } }
            let a = Annotation(kind: .counter(doc.nextCounter), start: p, end: p, color: style.color, thickness: style.thickness)
            doc.annotations.append(a)
            beginPlacing(a.id, at: p, alignedWith: lastCounter.map { bounds(of: $0) }, flags: flags)
        case .text:
            var a = Annotation(kind: .text(""), start: p, end: p, color: style.color, thickness: style.thickness, fontSize: doc.fontSize)
            a.variant = doc.textStyle.rawValue
            a.start.y -= doc.fontSize * 0.62
            doc.annotations.append(a)
            doc.selectedID = a.id
            placedTextID = a.id
            beginTextEditing(a.id)
            dragState = .none
        case .draw, .highlighter:
            var a = Annotation(kind: tool == .draw ? .draw : .highlighter, start: p, end: p, points: [p],
                               color: style.color, thickness: style.thickness)
            // Starting on a line of text: snap to it (⌥ draws freely).
            if tool == .highlighter, !flags.contains(.option), let line = doc.textLine(at: p) {
                a.variant = 1
                a.amount = line.height + 4
                a.points = [CGPoint(x: p.x, y: line.midY)]
            }
            doc.annotations.append(a)
            straightFrom = nil
            dragState = .creating(a.id)
        default:
            let kind: Annotation.Kind = switch tool {
            case .rectangle: .rectangle
            case .filledRectangle: .filledRectangle
            case .ellipse: .ellipse
            case .line: .line
            case .arrow: .arrow
            case .redact: .redact
            case .magnifier: .magnifier
            default: .spotlight
            }
            var a = Annotation(kind: kind, start: p, end: p, color: style.color, thickness: style.thickness)
            switch kind {
            case .redact: a.variant = doc.redactMode.rawValue; a.amount = doc.redactAmount
            case .spotlight:
                a.variant = doc.spotlightShape.rawValue
                a.spotBrightness = doc.spotlightBrightness
                a.restBrightness = doc.spotlightRest
                a.spotKeepsAnnotations = doc.spotlightKeepsAnnotations
                a.spotSoftness = doc.spotlightSoftness
                a.spotBorder = doc.spotlightBorder
            case .arrow: a.variant = doc.arrowStyle.rawValue
            case .magnifier: doc.applyMagnifierOptions(to: &a)
            default: break
            }
            doc.annotations.append(a)
            dragState = .creating(a.id)
        }
    }

    /// Moving an object: the offsets add up from where the drag started, so ⇧ can keep it on one axis.
    private func beginMove(_ id: UUID, at p: CGPoint) {
        moveStart = p
        moveApplied = .zero
        alignTarget = nil
        dragState = .moving(id, last: p)
    }

    /// A counter or emoji just placed follows the pointer until the button comes up; ⇧ lines it up with the
    /// previous one (`target`, its bounds).
    private func beginPlacing(_ id: UUID, at p: CGPoint, alignedWith target: CGRect?, flags: NSEvent.ModifierFlags) {
        placedID = id
        beginMove(id, at: p)
        alignTarget = target.map { CGPoint(x: $0.midX, y: $0.midY) }
        drag(to: p, flags: flags)
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
        drag(to: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    /// One step of the current drag; also re-run when a modifier key goes down or up mid-drag, so ⇧ and ⌥ act live.
    private func drag(to p: CGPoint, flags: NSEvent.ModifierFlags) {
        lastDragPoint = p
        let shift = flags.contains(.shift), option = flags.contains(.option)
        let anchor = arrowAnchor
        switch dragState {
        case .none:
            break
        case .creating(let id):
            update(id) { a in
                switch a.kind {
                case .highlighter where a.variant == 1:
                    a.points = [a.points[0], CGPoint(x: p.x, y: a.points[0].y)]
                case .draw, .highlighter:
                    if shift {
                        // ⇧: a straight segment from where it went down (45° steps); the stroke goes on from its end.
                        let from = self.straightFrom ?? a.points.count - 1
                        self.straightFrom = from
                        a.points = Array(a.points[...from]) + [Self.snapAngle(from: a.points[from], to: p)]
                    } else {
                        self.straightFrom = nil
                        if let last = a.points.last, hypot(p.x - last.x, p.y - last.y) > 1.5 / self.magnification { a.points.append(p) }
                    }
                case .arrow:
                    self.placeArrow(&a, tip: p, flags: flags)
                case .line:
                    a.end = shift ? Self.snapAngle(from: anchor, to: p) : p
                    // ⌥: from the center out.
                    a.start = option ? CGPoint(x: 2 * anchor.x - a.end.x, y: 2 * anchor.y - a.end.y) : anchor
                case .magnifier:
                    // A callout's drag is the area; an in-place drag is the lens (the area is the lens / zoom).
                    let end = shift ? Self.square(from: anchor, to: p) : p
                    let start = option ? CGPoint(x: 2 * anchor.x - end.x, y: 2 * anchor.y - end.y) : anchor
                    if a.magnifierStyle == .inPlace {
                        let c = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), z = a.magnification
                        let hw = abs(end.x - start.x) / 2 / z, hh = abs(end.y - start.y) / 2 / z
                        a.start = CGPoint(x: c.x - hw, y: c.y - hh)
                        a.end = CGPoint(x: c.x + hw, y: c.y + hh)
                    } else {
                        a.start = start
                        a.end = end
                        self.doc.placeBubble(&a)
                    }
                default:
                    a.end = shift ? Self.square(from: anchor, to: p) : p
                    a.start = option ? CGPoint(x: 2 * anchor.x - a.end.x, y: 2 * anchor.y - a.end.y) : anchor
                }
            }
        case .moving(let id, _):
            var d = CGVector(dx: p.x - moveStart.x, dy: p.y - moveStart.y)
            if shift, let target = alignTarget, let a = doc.annotations.first(where: { $0.id == id }) {
                // Placing: line up with the previous counter or emoji on the nearer axis.
                let box = bounds(of: a)
                let center = CGPoint(x: box.midX - moveApplied.dx + d.dx, y: box.midY - moveApplied.dy + d.dy)
                if abs(center.x - target.x) < abs(center.y - target.y) { d.dx += target.x - center.x } else { d.dy += target.y - center.y }
            } else if shift, alignTarget == nil {
                // Moving: only along the axis it moved most.
                if abs(d.dx) > abs(d.dy) { d.dy = 0 } else { d.dx = 0 }
            }
            let step = CGVector(dx: d.dx - moveApplied.dx, dy: d.dy - moveApplied.dy)
            moveApplied = d
            let part = movingPart
            update(id) { a in
                switch part {
                case .bubble?:
                    let c = a.magCenter ?? CGPoint(x: a.bubbleRect.midX, y: a.bubbleRect.midY)
                    a.magCenter = CGPoint(x: c.x + step.dx, y: c.y + step.dy)
                case .area?:
                    // The bubble stays where it is.
                    let c = a.magCenter ?? CGPoint(x: a.bubbleRect.midX, y: a.bubbleRect.midY)
                    a.offset(by: step)
                    a.magCenter = c
                case nil:
                    a.offset(by: step)
                }
            }
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
                case .lensTopLeft, .lensTopRight, .lensBottomRight, .lensBottomLeft:
                    // A callout's bubble sets the zoom (around its center); an in-place lens sets the area's size.
                    let b = a.bubbleRect, c = CGPoint(x: b.midX, y: b.midY)
                    let half = CGSize(width: max(abs(p.x - c.x), 8), height: max(abs(p.y - c.y), 8))
                    if a.magnifierStyle == .inPlace {
                        let z = a.magnification
                        let hw = shift ? max(half.width, half.height) / z : half.width / z
                        let hh = shift ? max(half.width, half.height) / z : half.height / z
                        a.start = CGPoint(x: c.x - hw, y: c.y - hh)
                        a.end = CGPoint(x: c.x + hw, y: c.y + hh)
                    } else {
                        a.magCenter = a.magCenter ?? c
                        a.magZoom = MagnifierZoom.clamp(half.width * 2 / max(a.rect.width, 1))
                        self.doc.magnifierZoom = a.magnification
                    }
                    return
                }
                // Added images keep their proportions; other shapes do while ⇧ is down.
                if case .image(let key) = a.kind, let image = self.doc.images[key] {
                    Self.keepAspect(&a, aspect: CGFloat(image.width) / CGFloat(max(image.height, 1)), handle: handle)
                } else if shift, a.isRectLike {
                    Self.keepAspect(&a, aspect: self.resizeAspect, handle: handle)
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            if spaceHeld { NSCursor.openHand.set() }
            return
        }
        // New objects stay unselected unless the setting keeps them selected.
        let selectPlaced = Defaults[Prefs.annotateSelectPlaced]
        if case .creating(let id) = dragState, let a = doc.annotations.first(where: { $0.id == id }) {
            if a.kind == .magnifier, a.rect.width < 4 || a.rect.height < 4 {
                // A click: a 60 pt area at that point.
                update(id) { m in
                    let c = self.arrowAnchor
                    m.start = CGPoint(x: c.x - 30, y: c.y - 30)
                    m.end = CGPoint(x: c.x + 30, y: c.y + 30)
                    if m.magnifierStyle == .callout { self.doc.placeBubble(&m) }
                }
            }
            let tooSmall: Bool = switch doc.annotations.first(where: { $0.id == id })?.kind ?? a.kind {
            case .magnifier: false
            case .draw, .highlighter: false
            case .line, .arrow: hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 4
            default: a.rect.width < 4 || a.rect.height < 4
            }
            if tooSmall { doc.annotations.removeAll { $0.id == id } } else if selectPlaced { doc.selectedID = id }
        }
        if let id = placedID, selectPlaced { doc.selectedID = id }
        placedID = nil
        alignTarget = nil
        if case .resizing(let id, _) = dragState { normalize(id) }
        movingPart = nil
        dragState = .none
        lastDragPoint = nil
        straightFrom = nil
        if doc.annotations != stateBeforeDrag { registerUndo(from: stateBeforeDrag, name: "Edit") }
        doc.isInteracting = false
    }

    /// Where the current drag started (arrows: "Inverse arrow direction" and ⌥ decide which end is the head).
    private var arrowAnchor: CGPoint = .zero
    private var lastDragPoint: CGPoint?
    /// Moving: where it started and how far the object has moved so far.
    private var moveStart: CGPoint = .zero
    private var moveApplied: CGVector = .zero
    /// Placing a counter or emoji: the center of the previous one (⇧ lines up with it).
    private var alignTarget: CGPoint?
    /// The counter or emoji being placed, and the text just placed (selected afterwards only with the setting on).
    private var placedID: UUID?
    private var placedTextID: UUID?
    /// Freehand with ⇧: the point the straight segment starts from.
    private var straightFrom: Int?
    /// Resizing with ⇧: the shape's proportions when the drag started.
    private var resizeAspect: CGFloat = 1

    /// Draws the arrow being created from the drag start to the pointer. "Inverse arrow direction" puts the head at
    /// the start; holding ⌥ flips that, live, as often as it's pressed or released during the drag.
    private func placeArrow(_ a: inout Annotation, tip p: CGPoint, flags: NSEvent.ModifierFlags) {
        let tip = flags.contains(.shift) ? Self.snapAngle(from: arrowAnchor, to: p) : p
        let inverted = Defaults[Prefs.annotateInverseArrow] != flags.contains(.option)
        (a.start, a.end) = inverted ? (tip, arrowAnchor) : (arrowAnchor, tip)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let p = lastDragPoint, !isPanning else { return }
        if case .none = dragState { return }
        drag(to: p, flags: event.modifierFlags)
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

    /// Corner resizing at a fixed width-to-height `aspect`: the dragged corner follows the width, the opposite corner
    /// stays put.
    private static func keepAspect(_ a: inout Annotation, aspect: CGFloat, handle: Handle) {
        let width = max(abs(a.end.x - a.start.x), 8)
        let height = width / max(aspect, 0.01)
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
        let style = TextStyle(variant: a.variant)
        let pad = style.hasBox ? AnnotationRenderer.boxPadding(a.fontSize) : .zero
        let tv = CanvasTextView(frame: CGRect(origin: CGPoint(x: a.start.x + pad.width, y: a.start.y + pad.height),
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
        tv.onFinish = { [weak self] in self?.endTextEditing() }
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
        let style = TextStyle(variant: a.variant)
        let s = (string.isEmpty ? " " : string) as NSString
        let r = s.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
                               attributes: [.font: style.font(size: a.fontSize)])
        return CGSize(width: ceil(r.width) + 2, height: ceil(r.height))
    }

    private func applyEditingStyle(to tv: NSTextView, annotation a: Annotation) {
        let style = TextStyle(variant: a.variant)
        let textColor = style.textColor(a.color)
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
        } else if !Defaults[Prefs.annotateSelectPlaced], placedTextID == id, doc.selectedID == id {
            // A new text stays unselected once it's written, like other new objects.
            doc.selectedID = nil
        }
        placedTextID = nil
        if doc.annotations != stateBeforeDrag { registerUndo(from: stateBeforeDrag, name: "Text") }
        window?.makeFirstResponder(self)
    }

    /// Restyles the text being edited (or the selection) after a toolbar change.
    func styleChanged() {
        if let tv = textView, let id = doc.editingTextID {
            update(id) { a in a.color = doc.color; a.fontSize = doc.fontSize; a.variant = doc.textStyle.rawValue }
            if let a = doc.annotations.first(where: { $0.id == id }) { applyEditingStyle(to: tv, annotation: a) }
            // Keep typing after picking an option in the sidebar.
            if window?.firstResponder !== tv { window?.makeFirstResponder(tv) }
            needsDisplay = true
        } else if doc.selected == nil, doc.tool == .counter {
            // Counter tool without a selection: the color goes to every counter.
            doc.recolorCounters()
        } else {
            doc.applyStyleToSelection()
        }
    }
}

/// The text being typed on the canvas: ⌘Return finishes it, like Esc.
private final class CanvasTextView: NSTextView {
    var onFinish: (() -> Void)?

    private func isFinish(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
            && [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(event.keyCode))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isFinish(event) { onFinish?(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isFinish(event) { onFinish?(); return }
        super.keyDown(with: event)
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
