import AppKit
import CoreImage

/// Per-tool option enums, matching the menus in the Annotate toolbar.

enum RedactMode: Int, CaseIterable {
    case pixelate, blurSecure, blurSmooth, blackOut
    /// Fills with the color around it (the background the text was on).
    case erase
    var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .blurSecure: "Blur (secure)"
        case .blurSmooth: "Blur (smooth)"
        case .blackOut: "Black Out"
        case .erase: "Erase"
        }
    }
    /// Whether the Strength slider changes it.
    var hasStrength: Bool { self != .blackOut && self != .erase }
    var symbol: String {
        switch self {
        case .pixelate: "checkerboard.rectangle"
        case .blurSecure: "drop.degreesign.fill"
        case .blurSmooth: "drop.fill"
        case .blackOut: "moon.fill"
        case .erase: "eraser.fill"
        }
    }
}

enum SpotlightShape: Int, CaseIterable {
    case rectangle, rounded, ellipse
    var title: String { ["Rectangle", "Rounded Rectangle", "Ellipse"][rawValue] }
    var symbol: String { ["square", "app", "circle"][rawValue] }
}

/// Magnifier: a callout (the area keeps showing; its enlarged copy sits elsewhere) or a lens over the area itself.
enum MagnifierStyle: Int, CaseIterable {
    case callout, inPlace
    var title: String { ["Callout", "In Place"][rawValue] }
    var help: String { ["The enlarged copy sits next to the area, linked to it", "A lens over the area itself"][rawValue] }
}

enum MagnifierShape: Int, CaseIterable {
    case circle, rounded
    var title: String { ["Circle", "Rounded Rectangle"][rawValue] }
    var symbol: String { ["circle", "app"][rawValue] }
}

/// What links a callout to its area.
enum MagnifierLink: Int, CaseIterable {
    case line, cone, none
    var title: String { ["Line", "Cone", "None"][rawValue] }
}

/// The magnifier's zoom range (sidebar slider, scrolling over a selected magnifier, resizing its bubble).
enum MagnifierZoom {
    static let range: ClosedRange<CGFloat> = 1.5...6
    static func clamp(_ z: CGFloat) -> CGFloat { min(max(z, range.lowerBound), range.upperBound) }
}

enum ArrowStyle: Int, CaseIterable {
    case standard, fancy, curved, double
    var title: String { ["Standard", "Fancy", "Curved", "Double"][rawValue] }
    var symbol: String { ["arrow.down.left", "arrow.down.left.circle", "arrow.uturn.left", "arrow.left.and.right"][rawValue] }
}

/// Raw values are stored in `Annotation.variant`; retired styles map to their closest one (`init(variant:)`).
enum TextStyle: Int, CaseIterable {
    /// Bold letters in the color; Outline adds a white edge that reads on any background.
    case standard = 0, outline = 2
    /// A colored box with white or black letters.
    case box = 4
    /// A white card with a colored border and colored letters.
    case card = 7
    /// Monospaced letters on a dark box, for commands and code.
    case code = 3
    /// Marker-pen letters, for handwritten-looking notes.
    case handwritten = 8

    static let allCases: [TextStyle] = [.standard, .outline, .box, .card, .code, .handwritten]

    /// The style stored in an annotation; the retired Rounded, Mono Box and Rounded Box become their closest style.
    init(variant: Int) {
        switch variant {
        case 5: self = .code
        case 6: self = .box
        default: self = TextStyle(rawValue: variant) ?? .standard
        }
    }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .outline: "Outline"
        case .box: "Box"
        case .card: "Card"
        case .code: "Code"
        case .handwritten: "Handwritten"
        }
    }

    var hasBox: Bool { [.box, .card, .code].contains(self) }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .standard, .outline, .box, .card: NSFont.systemFont(ofSize: size, weight: .bold)
        case .code: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        case .handwritten:
            NSFont(name: "MarkerFelt-Wide", size: size) ?? NSFont(name: "Noteworthy-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .bold)
        }
    }

    /// The letters' color for an object in `color`.
    func textColor(_ color: AnnotationColor) -> NSColor {
        switch self {
        case .box: color.prefersWhiteText ? .white : .black
        // White letters would vanish on the white card; dark ones would on the dark box.
        case .card: color.hex == 0xFFFFFF ? .black : color.nsColor
        case .code: color.isDark ? .white : color.nsColor
        default: color.nsColor
        }
    }
}

enum CounterStyle: Int, CaseIterable, Codable {
    case numbers, upperLetters, roman, lowerLetters
    var title: String { ["1, 2, 3, 4 …", "A, B, C, D …", "I, II, III, IV …", "a, b, c, d …"][rawValue] }

    func label(_ n: Int) -> String {
        switch self {
        case .numbers: return "\(n)"
        case .upperLetters: return Self.letters(n)
        case .lowerLetters: return Self.letters(n).lowercased()
        case .roman: return Self.roman(n)
        }
    }

    private static func letters(_ n: Int) -> String {
        var n = max(n, 1), s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(65 + n % 26)!) + s; n /= 26 }
        return s
    }

    private static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = max(n, 1), s = ""
        for (v, r) in table { while n >= v { s += r; n -= v } }
        return s
    }
}

/// Settings shared by all counters in a document.
struct CounterSettings: Equatable, Codable {
    var style: CounterStyle = .numbers
    var start = 1
    /// 0…1 → diameter 14…72pt.
    var size: CGFloat = 0.3
    var diameter: CGFloat { 14 + size * 58 }

    /// The thickness button's six steps as counter diameters (step 2 is the default size).
    private static let stepDiameters: [CGFloat] = [20, 25, 31.4, 40, 50, 62]

    /// The thickness step closest to the current size.
    var thicknessStep: Int {
        Self.stepDiameters.indices.min { abs(Self.stepDiameters[$0] - diameter) < abs(Self.stepDiameters[$1] - diameter) } ?? 2
    }

    /// The settings one counter is drawn with: the shared ones with its own overrides.
    func resolved(for a: Annotation) -> CounterSettings {
        var s = self
        if let style = a.counterStyle.flatMap(CounterStyle.init(rawValue:)) { s.style = style }
        if let size = a.counterSize { s.size = size }
        return s
    }

    mutating func setThicknessStep(_ step: Int) {
        size = (Self.stepDiameters[min(max(step, 0), Self.stepDiameters.count - 1)] - 14) / 58
    }
}

/// Cached obscured versions of the screenshot for the Redact tool.
final class RedactEffects {
    private let base: CGImage
    private let scale: CGFloat
    private var cache: [String: CGImage] = [:]
    private let context = CIContext()

    init(base: CGImage, scale: CGFloat) { self.base = base; self.scale = scale }

    /// Text line boxes in the screenshot (points, top-left origin), for Redact's Text only; empty until found.
    var textLines: [CGRect] = []

    /// The parts of `rect` that Text only covers: each text line inside it, a little bigger so ascenders,
    /// descenders and the first and last letters stay covered. nil when no text was found there (then the whole
    /// box is redacted, so nothing is left showing by surprise).
    func textParts(in rect: CGRect) -> [CGRect]? {
        let parts = textLines.compactMap { line -> CGRect? in
            // Lines the box really reaches into (not just their padding); a box over half a line covers that half.
            let overlap = line.intersection(rect)
            guard !overlap.isNull, overlap.height >= line.height * 0.3, overlap.width > 0 else { return nil }
            let padded = line.insetBy(dx: -max(2, line.height * 0.2), dy: -max(1.5, line.height * 0.2))
            return padded.intersection(rect)
        }
        return parts.isEmpty ? nil : parts
    }

    /// Erase: the most common color in a thin ring just outside `rect` (points), i.e. the background around it.
    func surroundingColor(of rect: CGRect) -> CGColor {
        let key = "ring-\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)"
        if let cached = colorCache[key] { return cached }
        let color = Self.dominantColor(base, scale: scale, inner: rect, ring: 3) ?? NSColor.white.cgColor
        colorCache[key] = color
        return color
    }
    private var colorCache: [String: CGColor] = [:]

    private static func dominantColor(_ image: CGImage, scale: CGFloat, inner: CGRect, ring: CGFloat) -> CGColor? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        func px(_ r: CGRect) -> CGRect { CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale) }
        let outer = px(inner.insetBy(dx: -ring, dy: -ring)).integral.intersection(bounds)
        let hole = px(inner)
        guard !outer.isEmpty, let crop = image.cropping(to: outer) else { return nil }
        let w = crop.width, h = crop.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Pixels of the ring only (the box itself holds the text), bucketed at 5 bits a channel; the fullest
        // bucket's average wins. A box at the image's edge has no ring there: then its own pixels count too.
        var sums: [Int: (r: Int, g: Int, b: Int, n: Int)] = [:]
        var ringPixels = 0
        for pass in 0..<2 {
            for y in 0..<h {
                // The buffer's first row is the crop's top row (image pixels, top-left origin like `outer`).
                let iy = CGFloat(outer.minY) + CGFloat(y) + 0.5
                for x in 0..<w {
                    let ix = CGFloat(outer.minX) + CGFloat(x) + 0.5
                    if pass == 0, hole.contains(CGPoint(x: ix, y: iy)) { continue }
                    let i = (y * w + x) * 4
                    let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                    let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                    let s = sums[key] ?? (0, 0, 0, 0)
                    sums[key] = (s.r + r, s.g + g, s.b + b, s.n + 1)
                    ringPixels += pass == 0 ? 1 : 0
                }
            }
            if pass == 0, ringPixels >= 8 { break }
        }
        guard let best = sums.values.max(by: { $0.n < $1.n }), best.n > 0 else { return nil }
        let n = CGFloat(best.n) * 255
        return CGColor(srgbRed: CGFloat(best.r) / n, green: CGFloat(best.g) / n, blue: CGFloat(best.b) / n, alpha: 1)
    }

    /// The screenshot `factor` times as bright (spotlights), in steps of 5%.
    func brightened(_ factor: CGFloat) -> CGImage? {
        let bucket = Int((factor * 20).rounded())
        let key = "bright-\(bucket)"
        if let cached = cache[key] { return cached }
        let f = CGFloat(bucket) / 20
        let output = CIImage(cgImage: base).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let image = context.createCGImage(output, from: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        cache[key] = image
        return image
    }

    /// Full-size obscured image for a mode and strength (0…1); nil for Black Out.
    func image(_ mode: RedactMode, amount: CGFloat) -> CGImage? {
        guard mode.hasStrength else { return nil }
        let bucket = Int((amount * 10).rounded())
        let key = "\(mode.rawValue)-\(bucket)"
        if let cached = cache[key] { return cached }
        let strength = CGFloat(bucket) / 10
        let input = CIImage(cgImage: base).clampedToExtent()
        var output: CIImage
        switch mode {
        case .pixelate:
            // At least 8 pt blocks: smaller ones can leave text guessable (known depixelation attacks).
            output = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: (8 + strength * 22) * scale,
                                                                      kCIInputCenterKey: CIVector(x: 0, y: 0)])
        case .blurSecure:
            // Mosaic first, then blur: looks soft but the original pixels can't be recovered.
            output = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: (6 + strength * 14) * scale,
                                                                      kCIInputCenterKey: CIVector(x: 0, y: 0)])
                .clampedToExtent().applyingGaussianBlur(sigma: Double((4 + strength * 14) * scale))
        case .blurSmooth:
            output = input.applyingGaussianBlur(sigma: Double((2 + strength * 20) * scale))
        case .blackOut, .erase:
            return nil
        }
        output = output.cropped(to: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let image = context.createCGImage(output, from: output.extent)
        cache[key] = image
        return image
    }
}
