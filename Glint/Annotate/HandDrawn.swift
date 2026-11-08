import CoreGraphics
import Foundation

/// The hand-drawn ("sketch") look for rectangles, ellipses, lines and arrows, in the spirit of rough.js: every edge is
/// drawn twice with a slight wobble, corners overshoot a little, filled shapes are hatched. The randomness comes from
/// the object's stored seed, so a shape keeps its sketch when it's moved or resized (⌘R picks a new seed).
enum HandDrawn {
    /// Subtle, Medium, Wild (`Annotation.sketch`, 1…3).
    enum Roughness: Int, CaseIterable {
        case subtle = 1, medium, wild
        var title: String { ["Subtle", "Medium", "Wild"][rawValue - 1] }
        var factor: CGFloat { [0.55, 1.1, 2.0][rawValue - 1] }
    }

    /// Which tools can draw hand-drawn.
    static let tools: Set<AnnotateTool> = [.rectangle, .filledRectangle, .ellipse, .line, .arrow]

    static func newSeed() -> UInt64 { UInt64.random(in: 1...UInt64.max) }

    /// Small deterministic generator (SplitMix64).
    struct Random {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return CGFloat(z >> 11) / CGFloat(1 << 53)
        }
        /// -1 … 1
        mutating func signed() -> CGFloat { next() * 2 - 1 }
    }

    // MARK: Paths

    /// A wobbly line from `a` to `b`, drawn twice (the second pass a little different).
    static func line(_ a: CGPoint, _ b: CGPoint, roughness r: CGFloat, random: inout Random, into path: CGMutablePath, passes: Int = 2) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        // Long lines wobble a little more, short ones less (rough.js scales its offset the same way).
        let offset = r * min(max(length * 0.025, 1), 4.5)
        for pass in 0..<passes {
            let o = pass == 0 ? offset : offset * 0.75
            func jitter(_ p: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: p.x + random.signed() * o * k, y: p.y + random.signed() * o * k) }
            let start = jitter(a, 0.6), end = jitter(b, 0.6)
            // Two control points near 1/3 and 2/3 (with a random bend), like a quick pen stroke.
            let t1 = 0.25 + random.next() * 0.2, t2 = 0.55 + random.next() * 0.2
            let c1 = jitter(CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1), 1)
            let c2 = jitter(CGPoint(x: a.x + (b.x - a.x) * t2, y: a.y + (b.y - a.y) * t2), 1)
            path.move(to: start)
            path.addCurve(to: end, control1: c1, control2: c2)
        }
    }

    /// The four sides, each a little longer than the side (corners overshoot).
    static func rectangle(_ r: CGRect, roughness k: CGFloat, seed: UInt64) -> CGPath {
        var random = Random(seed)
        let path = CGMutablePath()
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let ux = (b.x - a.x) / len, uy = (b.y - a.y) / len
            let over = k * min(len * 0.04, 5) * (0.4 + random.next() * 0.6)
            line(CGPoint(x: a.x - ux * over, y: a.y - uy * over), CGPoint(x: b.x + ux * over * 0.7, y: b.y + uy * over * 0.7),
                 roughness: k, random: &random, into: path)
        }
        return path
    }

    /// An ellipse drawn as a loop through jittered points, twice, overlapping where it closes.
    static func ellipse(_ r: CGRect, roughness k: CGFloat, seed: UInt64) -> CGPath {
        var random = Random(seed)
        let path = CGMutablePath()
        let c = CGPoint(x: r.midX, y: r.midY), rx = r.width / 2, ry = r.height / 2
        let size = max(rx, ry)
        let steps = max(10, min(Int(size / 6), 36))
        for pass in 0..<2 {
            let start = random.next() * .pi * 2
            let overlap = (0.12 + random.next() * 0.2) * (pass == 0 ? 1 : 0.6)
            let wobble = k * min(max(size * 0.03, 0.8), 4) * (pass == 0 ? 1 : 0.8)
            var points: [CGPoint] = []
            let count = steps + Int((CGFloat(steps) * overlap).rounded(.up))
            for i in 0...count {
                let angle = start + (CGFloat(i) / CGFloat(steps)) * .pi * 2
                let jx = random.signed() * wobble, jy = random.signed() * wobble
                points.append(CGPoint(x: c.x + cos(angle) * rx + jx, y: c.y + sin(angle) * ry + jy))
            }
            addSmoothCurve(points, to: path)
        }
        return path
    }

    /// Hatching inside `clip`: parallel strokes at about -41° (rough.js's default), `gap` apart.
    static func hatch(_ bounds: CGRect, gap: CGFloat, roughness k: CGFloat, seed: UInt64) -> CGPath {
        var random = Random(seed ^ 0xA5A5_5A5A)
        let path = CGMutablePath()
        let angle: CGFloat = -41 * .pi / 180
        let dx = cos(angle), dy = sin(angle), nx = -dy, ny = dx
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let reach = hypot(bounds.width, bounds.height) / 2 + gap
        var t = -reach
        while t <= reach {
            let o = CGPoint(x: c.x + nx * t, y: c.y + ny * t)
            line(CGPoint(x: o.x - dx * reach, y: o.y - dy * reach), CGPoint(x: o.x + dx * reach, y: o.y + dy * reach),
                 roughness: k * 0.6, random: &random, into: path, passes: 1)
            t += gap
        }
        return path
    }

    /// An open "V" head at `tip`, pointing away from `from`.
    static func head(tip: CGPoint, from: CGPoint, width w: CGFloat, roughness k: CGFloat, random: inout Random, into path: CGMutablePath) {
        let dx = tip.x - from.x, dy = tip.y - from.y, len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let size = max(w * 3.4, 16)
        for side: CGFloat in [-1, 1] {
            let spread = 0.5 + random.signed() * 0.06  // ~29°
            let ax = ux * cos(spread) - side * uy * sin(spread), ay = uy * cos(spread) + side * ux * sin(spread)
            line(tip, CGPoint(x: tip.x - ax * size, y: tip.y - ay * size), roughness: k * 0.7, random: &random, into: path)
        }
    }

    /// A wobbly quadratic curve (curved and double arrows) as short rough segments.
    static func curve(from a: CGPoint, control c: CGPoint, to b: CGPoint, roughness k: CGFloat, random: inout Random, into path: CGMutablePath) {
        for pass in 0..<2 {
            var points: [CGPoint] = []
            let wobble = k * (pass == 0 ? 1.2 : 0.9)
            for i in 0...12 {
                let t = CGFloat(i) / 12, u = 1 - t
                let p = CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
                points.append(CGPoint(x: p.x + random.signed() * wobble, y: p.y + random.signed() * wobble))
            }
            addSmoothCurve(points, to: path)
        }
    }

    /// Catmull-Rom through the points, as cubic Béziers.
    private static func addSmoothCurve(_ p: [CGPoint], to path: CGMutablePath) {
        guard p.count > 1 else { return }
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[i + 1], p3 = p[min(i + 2, p.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }
}
