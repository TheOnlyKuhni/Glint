import AppKit
import CoreImage

/// Per-tool option enums, matching the menus in the Annotate toolbar.

enum RedactMode: Int, CaseIterable {
    case pixelate, blurSecure, blurSmooth, blackOut
    var title: String {
        switch self {
        case .pixelate: "Pixelate"
        case .blurSecure: "Blur (secure)"
        case .blurSmooth: "Blur (smooth)"
        case .blackOut: "Black Out"
        }
    }
    var symbol: String {
        switch self {
        case .pixelate: "checkerboard.rectangle"
        case .blurSecure: "drop.degreesign.fill"
        case .blurSmooth: "drop.fill"
        case .blackOut: "moon.fill"
        }
    }
}

enum SpotlightShape: Int, CaseIterable {
    case rectangle, rounded, ellipse
    var title: String { ["Rectangle", "Rounded Rectangle", "Ellipse"][rawValue] }
    var symbol: String { ["square", "app", "circle"][rawValue] }
}

enum ArrowStyle: Int, CaseIterable {
    case standard, fancy, curved, double
    var title: String { ["Standard", "Fancy", "Curved", "Double"][rawValue] }
    var symbol: String { ["arrow.down.left", "arrow.down.left.circle", "arrow.uturn.left", "arrow.left.and.right"][rawValue] }
}

enum TextStyle: Int, CaseIterable {
    case standard, rounded, outlined, mono, box, monoBox, roundedBox
    var title: String { ["Standard", "Rounded", "Outlined", "Mono", "Box", "Mono Box", "Rounded Box"][rawValue] }
    var hasBox: Bool { [.box, .monoBox, .roundedBox].contains(self) }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .standard, .outlined, .box: NSFont.systemFont(ofSize: size, weight: .bold)
        case .rounded, .roundedBox: NSFont.rounded(size: size, weight: .bold)
        case .mono, .monoBox: NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
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

    /// Full-size obscured image for a mode and strength (0…1); nil for Black Out.
    func image(_ mode: RedactMode, amount: CGFloat) -> CGImage? {
        guard mode != .blackOut else { return nil }
        let bucket = Int((amount * 10).rounded())
        let key = "\(mode.rawValue)-\(bucket)"
        if let cached = cache[key] { return cached }
        let strength = CGFloat(bucket) / 10
        let input = CIImage(cgImage: base).clampedToExtent()
        var output: CIImage
        switch mode {
        case .pixelate:
            output = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: (5 + strength * 25) * scale,
                                                                      kCIInputCenterKey: CIVector(x: 0, y: 0)])
        case .blurSecure:
            // Mosaic first, then blur: looks soft but the original pixels can't be recovered.
            output = input.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: (6 + strength * 14) * scale,
                                                                      kCIInputCenterKey: CIVector(x: 0, y: 0)])
                .clampedToExtent().applyingGaussianBlur(sigma: Double((4 + strength * 14) * scale))
        case .blurSmooth:
            output = input.applyingGaussianBlur(sigma: Double((2 + strength * 20) * scale))
        case .blackOut:
            return nil
        }
        output = output.cropped(to: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let image = context.createCGImage(output, from: output.extent)
        cache[key] = image
        return image
    }
}
