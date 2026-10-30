import AppKit
import Observation

/// State of one Annotate window: the screenshot, its annotations and the current tool settings.
@Observable
final class AnnotationDocument {
    private(set) var baseImage: CGImage
    /// Size in points (pixels / scale).
    private(set) var imageSize: CGSize
    let scale: CGFloat
    /// Name used for "Save as…" and drag & drop.
    var fileName: String

    var annotations: [Annotation] = [] { didSet { isDirty = true; if !isInteracting { updateExpansion() } } }
    /// A drag is in progress: the canvas only grows (Automatically expand canvas) once it ends.
    @ObservationIgnored var isInteracting = false { didSet { if !isInteracting { updateExpansion() } } }
    /// Room added around the canvas so every annotation fits (Annotate setting "Automatically expand canvas").
    private(set) var expansion = BackgroundStyle.Insets()
    /// "Grow canvas": annotations past the screenshot widen the canvas; off, their outside parts are cut off.
    var expandsCanvas = Defaults[Prefs.annotateExpandCanvas] { didSet { if expandsCanvas != oldValue { updateExpansion() } } }
    var selectedID: UUID? { didSet { if selectedID != oldValue { onSelectionChange?() } } }
    /// Lets the toolbar follow the selection (it shows the selected object's options).
    @ObservationIgnored var onSelectionChange: (() -> Void)?
    var editingTextID: UUID?
    var tool: AnnotateTool = .highlighter
    var color: AnnotationColor = .red
    var thickness = AnnotationStyle.defaultThickness
    var fontSize: CGFloat = 30
    /// Backdrop from the Background tool; nil = none.
    var background: BackgroundStyle? { didSet { isDirty = true; updateExpansion() } }
    var isBackgroundPanelOpen = false
    /// Window capture (raw window with its own shadow): only Padding is adjustable in the Background tool.
    var isWindowCapture = false

    var layout: BackgroundStyle.Layout {
        displayBackground?.layout(for: imageSize) ?? BackgroundStyle.Layout(canvasSize: imageSize, imageOrigin: .zero)
    }

    /// The background as drawn and exported: the Background tool's, plus the automatic canvas expansion
    /// (transparent where there is no background).
    var displayBackground: BackgroundStyle? {
        guard !expansion.isZero else { return background }
        var bg = background ?? BackgroundStyle(fill: .transparent)
        bg.expansion = expansion
        return bg
    }

    /// Margin kept around annotations that reach past the canvas.
    private static let expansionMargin: CGFloat = 20

    private func updateExpansion() {
        var next = BackgroundStyle.Insets()
        if expandsCanvas, !isCropping {
            let base = background?.layout(for: imageSize) ?? BackgroundStyle.Layout(canvasSize: imageSize, imageOrigin: .zero)
            let canvas = CGRect(origin: CGPoint(x: -base.imageOrigin.x, y: -base.imageOrigin.y), size: base.canvasSize)
            // The furthest overshoot on any side, added on every side: the screenshot stays centered.
            var reach: CGFloat = 0
            for a in annotations {
                let r = bounds(of: a)
                guard r.width.isFinite, r.height.isFinite else { continue }
                reach = max(reach, canvas.minX - r.minX, canvas.minY - r.minY, r.maxX - canvas.maxX, r.maxY - canvas.maxY)
            }
            if reach > 0 {
                let e = (reach + Self.expansionMargin).rounded(.up)
                next = BackgroundStyle.Insets(top: e, left: e, bottom: e, right: e)
            }
        }
        if next != expansion { expansion = next }
    }

    /// How much of the document an annotation covers (points), including its stroke.
    func bounds(of a: Annotation) -> CGRect {
        switch a.kind {
        case .text(let s):
            return CGRect(origin: a.start, size: AnnotationRenderer.styledTextSize(s, size: a.fontSize, style: TextStyle(rawValue: a.variant) ?? .standard))
        case .counter(let n):
            let c = counter.resolved(for: a)
            let d = c.diameter
            let w = max(d, AnnotationRenderer.counterLabelWidth(c.style.label(c.start + n - 1), diameter: d))
            return CGRect(x: a.start.x - w / 2, y: a.start.y - d / 2, width: w, height: d)
        case .draw, .highlighter:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            let pad = a.kind == .highlighter ? AnnotationRenderer.highlighterWidth(of: a) / 2 : a.lineWidth / 2
            return CGRect(x: (xs.min() ?? 0) - pad, y: (ys.min() ?? 0) - pad,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0) + pad * 2, height: (ys.max() ?? 0) - (ys.min() ?? 0) + pad * 2)
        case .line, .arrow:
            var r = a.rect
            if let c = a.control { r = r.union(CGRect(origin: c, size: .zero)) }
            return r.insetBy(dx: -a.lineWidth * 2, dy: -a.lineWidth * 2)
        default:
            return a.rect.insetBy(dx: -a.lineWidth / 2, dy: -a.lineWidth / 2)
        }
    }
    private(set) var isDirty = false

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private(set) lazy var effects = RedactEffects(base: baseImage, scale: scale)
    /// Crop & Resize mode is active (the toolbar and canvas switch to crop controls).
    var isCropping = false { didSet { updateExpansion() } }

    // Per-tool options (toolbar menus).
    var redactMode: RedactMode = .pixelate
    var redactAmount: CGFloat = 0.5
    var spotlightShape: SpotlightShape = .rounded
    var spotlightAmount: CGFloat = 0.5
    var arrowStyle: ArrowStyle = .standard
    var textStyle: TextStyle = .standard
    /// Shared by every counter; changing the size resizes all of them.
    var counter = CounterSettings() { didSet { isDirty = true; updateExpansion() } }
    /// Images added with Add screenshot, by `Annotation.Kind.image` key (kept when an object is deleted, for undo).
    @ObservationIgnored var images: [String: CGImage] = [:]

    /// Adds an image as a movable object, `size` in points, centered on `center`, and selects it.
    func addImage(_ image: CGImage, size: CGSize, center: CGPoint) {
        let key = UUID().uuidString
        images[key] = image
        checkpoint("Add Screenshot")
        let origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
        let a = Annotation(kind: .image(key), start: origin, end: CGPoint(x: origin.x + size.width, y: origin.y + size.height),
                           color: color, thickness: thickness)
        annotations.append(a)
        selectedID = a.id
    }

    /// "Unlock canvas" toggle for Draw/Highlighter.
    var canvasUnlocked = false
    /// Text line boxes found in the screenshot (for the highlighter), filled in shortly after opening.
    @ObservationIgnored private(set) var textLines: [CGRect] = []

    func detectText() {
        let image = baseImage, scale = scale
        Task {
            textLines = await TextRecognizer.recognize(image, scale: scale).map(\.rect)
        }
    }

    /// The text line under a point, if any (a little vertical slack for imprecise clicks).
    func textLine(at p: CGPoint) -> CGRect? {
        textLines.filter { $0.insetBy(dx: -4, dy: -3).contains(p) }.min { $0.height < $1.height }
    }

    init(image: CGImage, scale: CGFloat, fileName: String) {
        baseImage = image
        self.scale = max(scale, 1)
        imageSize = CGSize(width: CGFloat(image.width) / self.scale, height: CGFloat(image.height) / self.scale)
        self.fileName = fileName
        detectText()
    }

    var selected: Annotation? {
        get { annotations.first { $0.id == selectedID } }
        set {
            guard let newValue, let i = annotations.firstIndex(where: { $0.id == newValue.id }) else { return }
            annotations[i] = newValue
        }
    }

    var nextCounter: Int {
        let numbers = annotations.compactMap { a -> Int? in if case .counter(let n) = a.kind { n } else { nil } }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: Undo

    /// Records the current annotations so the next change can be undone.
    func checkpoint(_ name: String) {
        let previous = annotations
        undoManager.registerUndo(withTarget: self) { doc in doc.restore(previous, name: name) }
        undoManager.setActionName(name)
    }

    private func restore(_ state: [Annotation], name: String) {
        let current = annotations
        undoManager.registerUndo(withTarget: self) { doc in doc.restore(current, name: name) }
        undoManager.setActionName(name)
        annotations = state
        if let id = selectedID, !state.contains(where: { $0.id == id }) { selectedID = nil }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint("Delete")
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func duplicateSelected() {
        guard var copy = selected?.duplicated() else { return }
        checkpoint("Duplicate")
        copy.offset(by: CGVector(dx: 16, dy: 16))
        if case .counter = copy.kind { copy.kind = .counter(nextCounter) }
        annotations.append(copy)
        selectedID = copy.id
    }

    /// Loads the selected object's style into the toolbar settings (so its options show its values).
    func adoptStyleOfSelection() {
        guard let a = selected else { return }
        let tool = AnnotateTool(drawing: a.kind)
        if tool.usesColor { color = a.color }
        // A counter's size is shared by all counters, not stored per object.
        if tool.usesThickness, tool != .counter { thickness = a.thickness }
        switch a.kind {
        case .redact: redactMode = RedactMode(rawValue: a.variant) ?? redactMode; redactAmount = a.amount
        case .spotlight: spotlightShape = SpotlightShape(rawValue: a.variant) ?? spotlightShape; spotlightAmount = a.amount
        case .arrow: arrowStyle = ArrowStyle(rawValue: a.variant) ?? arrowStyle
        case .text: textStyle = TextStyle(rawValue: a.variant) ?? textStyle; fontSize = a.fontSize
        default: break
        }
    }

    /// Applies the toolbar's color/thickness/size to the selected object.
    func applyStyleToSelection() {
        guard var a = selected else { return }
        checkpoint("Change Style")
        a.color = color
        a.thickness = thickness
        a.fontSize = fontSize
        switch a.kind {
        case .redact: a.variant = redactMode.rawValue; a.amount = redactAmount
        case .spotlight: a.variant = spotlightShape.rawValue; a.amount = spotlightAmount
        case .arrow: a.variant = arrowStyle.rawValue
        case .text: a.variant = textStyle.rawValue
        default: break
        }
        selected = a
    }

    // MARK: Counters

    private var selectedCounter: Annotation? {
        guard let a = selected, case .counter = a.kind else { return nil }
        return a
    }

    /// The counter options the toolbar shows: the selected counter's own values, otherwise the shared ones.
    var shownCounter: CounterSettings { selectedCounter.map { counter.resolved(for: $0) } ?? counter }

    /// Changes counter options: only the selected counter's when one is selected, otherwise every counter's
    /// (the changed option replaces their own values).
    func changeCounter(_ change: (inout CounterSettings) -> Void) {
        if var a = selectedCounter {
            var s = counter.resolved(for: a)
            change(&s)
            checkpoint("Change Style")
            a.counterStyle = s.style.rawValue
            a.counterSize = s.size
            selected = a
            return
        }
        let before = counter
        change(&counter)
        let styleChanged = counter.style != before.style, sizeChanged = counter.size != before.size
        guard styleChanged || sizeChanged,
              annotations.contains(where: { a in if case .counter = a.kind { (styleChanged && a.counterStyle != nil) || (sizeChanged && a.counterSize != nil) } else { false } })
        else { return }
        checkpoint("Change Style")
        for i in annotations.indices {
            guard case .counter = annotations[i].kind else { continue }
            if styleChanged { annotations[i].counterStyle = nil }
            if sizeChanged { annotations[i].counterSize = nil }
        }
    }

    /// Gives every counter the toolbar color (counter tool with nothing selected).
    func recolorCounters() {
        guard annotations.contains(where: { a in if case .counter = a.kind { a.color != color } else { false } }) else { return }
        checkpoint("Change Style")
        for i in annotations.indices {
            if case .counter = annotations[i].kind { annotations[i].color = color }
        }
    }

    func markSaved() { isDirty = false }

    /// Restores a re-editable save (`ImageEdit`).
    func restore(_ edit: ImageEdit) {
        annotations = edit.annotations
        background = edit.background
        counter = edit.counter
        isWindowCapture = edit.isWindowCapture
        markSaved()
    }

    // MARK: Crop & Resize

    /// Replaces the screenshot with `image` (annotations already flattened into it), undoable.
    func replaceImage(_ image: CGImage, name: String) {
        let previous = (baseImage, imageSize, annotations, realBackground)
        undoManager.registerUndo(withTarget: self) { doc in doc.restoreImage(previous, name: name) }
        undoManager.setActionName(name)
        setImage(image)
        annotations = []
        selectedID = nil
    }

    private func restoreImage(_ state: (CGImage, CGSize, [Annotation], BackgroundStyle?), name: String) {
        let current = (baseImage, imageSize, annotations, realBackground)
        undoManager.registerUndo(withTarget: self) { doc in doc.restoreImage(current, name: name) }
        undoManager.setActionName(name)
        setImage(state.0)
        annotations = state.2
        if isCropping { backgroundBeforeCrop = state.3 } else { background = state.3 }
        selectedID = nil
    }

    /// Rotate (90° clockwise) or mirror the screenshot; the annotations turn with it and stay editable. Undoable.
    func transform(rotate: Bool) {
        guard let image = CropState.transform(baseImage, rotate: rotate) else { return }
        let old = imageSize
        let previous = (baseImage, imageSize, annotations, realBackground)
        undoManager.registerUndo(withTarget: self) { doc in doc.restoreImage(previous, name: rotate ? "Rotate" : "Flip") }
        undoManager.setActionName(rotate ? "Rotate" : "Flip")
        let moved = annotations.map { transformed($0, rotate: rotate, in: old) }
        setImage(image)
        annotations = moved
    }

    /// Where an annotation goes when the screenshot (`size`) turns 90° clockwise or is mirrored left–right.
    /// Shapes and lines follow exactly; text, counters and added images keep their upright look and move with
    /// their center.
    private func transformed(_ a: Annotation, rotate: Bool, in size: CGSize) -> Annotation {
        func f(_ p: CGPoint) -> CGPoint { rotate ? CGPoint(x: size.height - p.y, y: p.x) : CGPoint(x: size.width - p.x, y: p.y) }
        var b = a
        switch a.kind {
        case .text, .counter, .image:
            let box = bounds(of: a)
            let c = f(CGPoint(x: box.midX, y: box.midY))
            b.offset(by: CGVector(dx: c.x - box.midX, dy: c.y - box.midY))
        case .line, .arrow:
            b.start = f(a.start); b.end = f(a.end); b.control = a.control.map(f)
        case .draw, .highlighter:
            b.points = a.points.map(f); b.start = f(a.start); b.end = f(a.end)
        default:
            let r = CGRect(corner: f(a.start), f(a.end))
            b.start = CGPoint(x: r.minX, y: r.minY); b.end = CGPoint(x: r.maxX, y: r.maxY)
        }
        return b
    }

    /// While cropping, `background` is the crop's transparent room; the user's background waits here.
    var backgroundBeforeCrop: BackgroundStyle?
    /// The ratio of the last applied crop (Crop & Resize starts with it again; nil = Freeform).
    var cropRatio: (ratio: CropState.Ratio, typed: CGSize?)?
    private var realBackground: BackgroundStyle? { isCropping ? backgroundBeforeCrop : background }

    private func setImage(_ image: CGImage) {
        baseImage = image
        imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        effects = RedactEffects(base: image, scale: scale)
        isDirty = true
        detectText()
    }

    /// The screenshot with annotations (no background), at full resolution.
    func flattened() -> CGImage? {
        AnnotationRenderer.export(base: baseImage, imageSize: imageSize, effects: effects, annotations: annotations, counter: counter,
                                  images: images)
    }

    // MARK: Output

    func renderedImage() -> CGImage? {
        AnnotationRenderer.export(base: baseImage, imageSize: imageSize, effects: effects, annotations: annotations,
                                  background: displayBackground, counter: counter, images: images)
    }
}
