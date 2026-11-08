import AppKit

/// Drawing tools of the Annotate editor, in toolbar order.
enum AnnotateTool: String, CaseIterable, Identifiable {
    case select, rectangle, filledRectangle, ellipse, line, arrow, text, redact, spotlight, magnifier, counter, emoji, draw, highlighter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Move"
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .redact: "Redact"
        case .spotlight: "Spotlight"
        case .magnifier: "Magnifier"
        case .counter: "Counter"
        case .emoji: "Emoji"
        case .draw: "Draw"
        case .highlighter: "Highlighter"
        }
    }

    /// Single-key shortcut.
    var key: String {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .filledRectangle: "f"
        case .ellipse: "e"
        case .line: "l"
        case .arrow: "a"
        case .text: "t"
        case .redact: "p"
        case .spotlight: "h"
        case .magnifier: "z"
        case .counter: "c"
        case .emoji: "j"
        case .draw: "d"
        case .highlighter: "m"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "square"
        case .filledRectangle: "square.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.down.left"
        case .text: "textformat.characters"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "rectangle.inset.filled"
        case .magnifier: "plus.magnifyingglass"
        case .counter: "1.circle.fill"
        case .emoji: "face.smiling"
        case .draw: "pencil"
        case .highlighter: "highlighter"
        }
    }

    /// The tool that draws this kind of object (its options show while it is selected).
    init(drawing kind: Annotation.Kind) {
        self = switch kind {
        case .rectangle: .rectangle
        case .filledRectangle: .filledRectangle
        case .ellipse: .ellipse
        case .redact: .redact
        case .spotlight: .spotlight
        case .magnifier: .magnifier
        case .line: .line
        case .arrow: .arrow
        case .draw: .draw
        case .highlighter: .highlighter
        case .text: .text
        case .counter: .counter
        case .image: .select
        }
    }

    var usesThickness: Bool { [.rectangle, .ellipse, .line, .arrow, .draw, .highlighter, .counter, .magnifier].contains(self) }
    var usesColor: Bool { ![.select, .redact, .spotlight, .emoji].contains(self) }
}

/// One object drawn on top of the screenshot. Value type, so undo is just keeping old arrays.
struct Annotation: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        case rectangle, filledRectangle, ellipse, redact, spotlight
        /// `rect` is the area that's enlarged; the enlarged copy (the bubble) is `bubbleRect`.
        case magnifier
        case line, arrow
        case draw, highlighter
        case text(String)
        case counter(Int)
        /// An added screenshot or image file (Add screenshot); the key looks it up in `AnnotationDocument.images`.
        case image(String)
    }

    let id: UUID
    var kind: Kind
    /// Shapes: the two corners. Lines/arrows: start and end. Text/counter: `start` is the anchor.
    var start: CGPoint
    var end: CGPoint
    /// Freehand points for draw/highlighter.
    var points: [CGPoint]
    var color: AnnotationColor
    var thickness: Int  // index into AnnotationStyle.thicknesses
    var fontSize: CGFloat
    /// Tool-specific style: RedactMode, SpotlightShape, ArrowStyle or TextStyle raw value.
    var variant = 0
    /// Redact strength, 0…1. Spotlights made before the brightness sliders: their dimming (see `spotRest`).
    var amount: CGFloat = 0.5
    /// Spotlights: brightness inside the spotlight and of everything else (1 = unchanged); nil = made before these
    /// existed (inside unchanged, outside dimmed by `amount`).
    var spotBrightness: CGFloat?
    var restBrightness: CGFloat?
    /// Spotlights: whether annotations outside stay as they are (nil = no, they're dimmed too), how soft the edge is
    /// (0…1; nil = made before Soft edge: hard), and whether a border in `color` goes around it.
    var spotKeepsAnnotations: Bool?
    var spotSoftness: CGFloat?
    var spotBorder: Bool?
    /// Curved and double arrows: the point the arrow bends through (set by dragging its middle handle).
    /// nil = straight (the default).
    var control: CGPoint?
    /// Counters: this counter's own numbering style and size (set while it's selected); nil = the shared setting.
    var counterStyle: Int?
    var counterSize: CGFloat?
    /// Magnifiers (`variant` is the `MagnifierShape`): the bubble's center (callouts), the zoom (nil = 2×), the
    /// `MagnifierStyle` and `MagnifierLink`, smooth instead of pixel-sharp scaling, and whether the annotations under
    /// the area are enlarged too (nil = yes).
    var magCenter: CGPoint?
    var magZoom: CGFloat?
    var magStyle: Int?
    var magLink: Int?
    var magSmooth: Bool?
    var magIncludes: Bool?

    init(kind: Kind, start: CGPoint, end: CGPoint, points: [CGPoint] = [], color: AnnotationColor, thickness: Int, fontSize: CGFloat = 30) {
        id = UUID()
        self.kind = kind
        self.start = start
        self.end = end
        self.points = points
        self.color = color
        self.thickness = thickness
        self.fontSize = fontSize
    }

    var rect: CGRect { CGRect(corner: start, end) }

    /// Arrow styles that bend through a draggable middle point.
    var isBendable: Bool {
        guard case .arrow = kind, let style = ArrowStyle(rawValue: variant) else { return false }
        return style == .curved || style == .double
    }

    /// Where the middle handle of a bendable arrow sits: its bend point, or halfway when straight.
    var bendPoint: CGPoint { control ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }

    /// Quadratic control point that makes the arrow pass through `bendPoint` halfway along.
    var curveControl: CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), h = bendPoint
        return CGPoint(x: 2 * h.x - mid.x, y: 2 * h.y - mid.y)
    }

    /// Points along a bendable arrow's curve (for hit testing).
    func curvePoints(_ count: Int = 24) -> [CGPoint] {
        let c = curveControl
        return (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count), u = 1 - t
            return CGPoint(x: u * u * start.x + 2 * u * t * c.x + t * t * end.x, y: u * u * start.y + 2 * u * t * c.y + t * t * end.y)
        }
    }
    var magnification: CGFloat { magZoom ?? 2 }
    var magnifierStyle: MagnifierStyle { MagnifierStyle(rawValue: magStyle ?? 0) ?? .callout }
    var magnifierLink: MagnifierLink { MagnifierLink(rawValue: magLink ?? 0) ?? .line }
    var magnifierShape: MagnifierShape { MagnifierShape(rawValue: variant) ?? .circle }

    /// Where the enlarged copy is shown: the area's size times the zoom, around `magCenter` (a callout) or over the
    /// area itself (in place).
    var bubbleRect: CGRect {
        let r = rect, z = magnification
        let center = magnifierStyle == .inPlace ? CGPoint(x: r.midX, y: r.midY) : (magCenter ?? CGPoint(x: r.midX, y: r.midY))
        return CGRect(x: center.x - r.width * z / 2, y: center.y - r.height * z / 2, width: r.width * z, height: r.height * z)
    }

    /// A spotlight's brightness inside it and outside it.
    var spotInside: CGFloat { spotBrightness ?? 1 }
    var spotRest: CGFloat { restBrightness ?? 1 - (0.15 + 0.75 * amount) }
    var spotSoft: CGFloat { spotSoftness ?? 0 }
    /// Spotlights saved before these settings kept annotations out of the dimming; they still do.
    var spotKeeps: Bool { spotKeepsAnnotations ?? (spotSoftness == nil) }

    var lineWidth: CGFloat { AnnotationStyle.thicknesses[min(max(thickness, 0), AnnotationStyle.thicknesses.count - 1)] }

    var isRectLike: Bool {
        switch kind {
        case .rectangle, .filledRectangle, .ellipse, .redact, .spotlight, .magnifier, .image: true
        default: false
        }
    }

    /// A copy with a new identity (for duplicating).
    func duplicated() -> Annotation {
        var copy = Annotation(kind: kind, start: start, end: end, points: points, color: color, thickness: thickness, fontSize: fontSize)
        copy.variant = variant
        copy.amount = amount
        copy.spotBrightness = spotBrightness
        copy.restBrightness = restBrightness
        copy.spotKeepsAnnotations = spotKeepsAnnotations
        copy.spotSoftness = spotSoftness
        copy.spotBorder = spotBorder
        copy.control = control
        copy.magCenter = magCenter
        copy.magZoom = magZoom
        copy.magStyle = magStyle
        copy.magLink = magLink
        copy.magSmooth = magSmooth
        copy.magIncludes = magIncludes
        return copy
    }

    mutating func offset(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
        control = control.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        magCenter = magCenter.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }
}

/// Colors from the palette, stored as Display P3 hex.
struct AnnotationColor: Equatable, Hashable, Codable {
    var hex: UInt32

    static let palette: [AnnotationColor] = [0x000000, 0xE5484A, 0xF09235, 0xFAE24C, 0x70D363, 0x66CCC1, 0x3478F6, 0x8254F6, 0xEA456D, 0xFFFFFF]
        .map(AnnotationColor.init(hex:))
    static let red = AnnotationColor(hex: 0xE5484A)

    var nsColor: NSColor {
        NSColor(displayP3Red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    var cgColor: CGColor { nsColor.cgColor }

    /// Whether white text reads well on this color (counters).
    var prefersWhiteText: Bool {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return true }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.75
    }

    /// Too dark to read on a dark box (black, very dark custom colors).
    var isDark: Bool {
        guard let c = nsColor.usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.3
    }

    init(hex: UInt32) { self.hex = hex }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.displayP3) ?? .red
        hex = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
    }
}

enum AnnotationStyle {
    /// The six "Thickness" steps; index 2 is the default (7pt).
    static let thicknesses: [CGFloat] = [3, 5, 7, 10, 14, 18]
    static let defaultThickness = 2
    static let fontSizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 30, 36, 48, 64, 72, 96]
}
