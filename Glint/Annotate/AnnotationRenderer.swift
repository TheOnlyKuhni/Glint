import AppKit
import CoreImage

/// Draws a screenshot and its annotations into a y-down CGContext in document points.
/// Used for both the editor canvas and export, so the result matches what's on screen.
struct AnnotationRenderer {
    let baseImage: CGImage
    let imageSize: CGSize           // in points
    let effects: RedactEffects?     // obscured versions of the screenshot for Redact
    /// Device pixels per point of the target context (for shadow sizing).
    var deviceScale: CGFloat = 2
    var drawsShadows = Defaults[Prefs.annotateShadow]
    var background: BackgroundStyle?
    var counter = CounterSettings()
    /// Added images (`Annotation.Kind.image`), by key.
    var images: [String: CGImage] = [:]
    /// Editor only: checker cell size (document points) behind a transparent background; nil = none.
    var transparencyGridCell: CGFloat?

    /// Which parts to draw. The editor draws the backdrop, the screenshot (a GPU layer) and the overlay separately.
    struct Parts: OptionSet {
        let rawValue: Int
        static let backdrop = Parts(rawValue: 1), image = Parts(rawValue: 2), overlay = Parts(rawValue: 4)
        static let all: Parts = [.backdrop, .image, .overlay]
    }

    func draw(_ annotations: [Annotation], in ctx: CGContext, editingTextID: UUID? = nil, parts: Parts = .all) {
        let bounds = CGRect(origin: .zero, size: imageSize)
        if parts.contains(.backdrop) {
            background?.drawBackdrop(imageSize: imageSize, baseImage: baseImage, ctx: ctx, deviceScale: deviceScale,
                                     gridCell: transparencyGridCell)
        }
        guard parts.contains(.image) || parts.contains(.overlay) else { return }
        // Spotlights: everything else (and the spotlights themselves) brightened or dimmed; the latest one's values.
        let spotlights = annotations.filter { $0.kind == .spotlight }
        let spots = CGMutablePath()
        for s in spotlights { spots.addPath(Self.spotPath(s)) }
        let last = spotlights.last
        let inside = last?.spotInside ?? 1, outside = last?.spotRest ?? 1
        let soft = Self.spotEdge(last?.spotSoft ?? 0)
        // Dimming covers the annotations outside the spotlights too, unless they're excluded.
        let dimsAnnotations = !(last?.spotKeeps ?? false)
        ctx.saveGState()
        background?.clipScreenshot(imageSize: imageSize, ctx: ctx)
        if parts.contains(.image) { Self.drawImage(baseImage, in: bounds, ctx: ctx) }
        if parts.contains(.overlay) {
            // Brightening draws the screenshot again, brighter, before the redactions go on top.
            if !spotlights.isEmpty, abs(inside - 1) > 0.01, let bright = effects?.brightened(inside) {
                ctx.saveGState()
                Self.clip(ctx, to: spots, inside: true, bounds: bounds, soft: soft)
                Self.drawImage(bright, in: bounds, ctx: ctx)
                ctx.restoreGState()
            }
            if !spotlights.isEmpty, outside > 1.01, let bright = effects?.brightened(outside) {
                ctx.saveGState()
                Self.clip(ctx, to: spots, inside: false, bounds: bounds, soft: soft)
                Self.drawImage(bright, in: bounds, ctx: ctx)
                ctx.restoreGState()
            }
            for a in annotations where a.kind == .redact { drawRedact(a, ctx: ctx) }
        }
        ctx.restoreGState()
        guard parts.contains(.overlay) else { return }

        // Dimming darkens the screenshot only, never the background around it: it keeps to the card's rounded
        // shape and, for captures with transparency (windows), to the screenshot's own pixels.
        func dim() {
            guard !spotlights.isEmpty, outside < 0.99 else { return }
            ctx.saveGState()
            background?.clipScreenshot(imageSize: imageSize, ctx: ctx)
            Self.clip(ctx, to: spots, inside: false, bounds: bounds, soft: soft)
            let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(baseImage.alphaInfo)
            if hasAlpha { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            ctx.setFillColor(NSColor.black.withAlphaComponent(1 - max(outside, 0)).cgColor)
            ctx.fill(bounds)
            if hasAlpha {
                ctx.setBlendMode(.destinationIn)
                Self.drawImage(baseImage, in: bounds, ctx: ctx)
                ctx.endTransparencyLayer()
            }
            ctx.restoreGState()
        }
        if !dimsAnnotations { dim() }

        let brightensAnnotations = dimsAnnotations && !spotlights.isEmpty && outside > 1.01
        // Annotations outside the spotlights get brighter with the screenshot: a white wash on top of them only.
        if brightensAnnotations { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
        for a in annotations where a.kind != .redact && a.kind != .spotlight {
            if a.id == editingTextID {
                // The text view shows the letters; keep the box or outline behind them.
                if case .text(let s) = a.kind, case let style = TextStyle(variant: a.variant), style.hasBox || style == .outline {
                    Self.drawStyledText(s, at: a.start, size: a.fontSize, color: a.color, style: style, backgroundOnly: true, ctx: ctx)
                }
                continue
            }
            draw(a, ctx: ctx)
        }
        if brightensAnnotations {
            ctx.saveGState()
            Self.clip(ctx, to: spots, inside: false, bounds: bounds, soft: soft)
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(NSColor.white.withAlphaComponent(min(outside - 1, 1) * 0.6).cgColor)
            ctx.fill(bounds.insetBy(dx: -bounds.width, dy: -bounds.height))
            ctx.restoreGState()
            ctx.endTransparencyLayer()
        }
        if dimsAnnotations { dim() }

        // The optional border, in the spotlight's color.
        for s in spotlights where s.spotBorder == true {
            ctx.saveGState()
            if drawsShadows {
                ctx.setShadow(offset: .zero, blur: 6 * deviceScale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            }
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(3)
            ctx.addPath(Self.spotPath(s))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: Spotlight

    /// A spotlight's outline; rounded corners grow with its size.
    static func spotPath(_ s: Annotation) -> CGPath {
        let r = s.rect
        switch SpotlightShape(rawValue: s.variant) ?? .rounded {
        case .rectangle: return CGPath(rect: r, transform: nil)
        case .rounded: return roundedRect(r, radius: min(max(10, min(r.width, r.height) * 0.12), 32))
        case .ellipse: return CGPath(ellipseIn: r, transform: nil)
        }
    }

    /// How far (points) a spotlight's edge fades, for its Soft edge setting (0…1).
    static func spotEdge(_ softness: CGFloat) -> CGFloat { softness * 48 }

    /// Clips to the spotlights (`inside`) or to everything else; a soft edge fades across the outline.
    private static func clip(_ ctx: CGContext, to spots: CGPath, inside: Bool, bounds: CGRect, soft: CGFloat) {
        if soft > 0.5, let mask = SpotMask.shared.mask(spots, size: bounds.size, edge: soft, inside: inside) {
            // The mask is a top-down image like the screenshot: flip it upright the way `drawImage` does.
            ctx.translateBy(x: 0, y: bounds.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.clip(to: CGRect(origin: .zero, size: bounds.size), mask: mask)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -bounds.maxY)
        } else if inside {
            ctx.addPath(spots)
            ctx.clip()
        } else {
            ctx.addRect(bounds.insetBy(dx: -bounds.width, dy: -bounds.height))
            ctx.addPath(spots)
            ctx.clip(using: .evenOdd)
        }
    }

    func draw(_ a: Annotation, ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = a.color.cgColor
        let w = a.lineWidth
        if drawsShadows, a.kind != .highlighter {
            ctx.setShadow(offset: CGSize(width: 0, height: -1 * deviceScale), blur: 4 * deviceScale,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .image(let key):
            if let image = images[key] { Self.drawImage(image, in: a.rect, ctx: ctx) }
        case .rectangle:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.addPath(Self.roundedRect(a.rect, radius: min(2, w / 2)))
            ctx.strokePath()
        case .filledRectangle:
            ctx.setFillColor(color)
            ctx.addPath(Self.roundedRect(a.rect, radius: 4))
            ctx.fillPath()
        case .ellipse:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.strokeEllipse(in: a.rect)
        case .line:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(w)
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .arrow:
            Self.drawArrow(a, style: ArrowStyle(rawValue: a.variant) ?? .standard, color: color, width: w, ctx: ctx)
        case .draw:
            ctx.setStrokeColor(color)
            ctx.setLineWidth(max(2, w * 0.75))
            ctx.addPath(Self.smoothPath(a.points))
            ctx.strokePath()
        case .highlighter:
            if a.variant == 1, let first = a.points.first, let last = a.points.last {
                // Snapped to a text line: a straight band exactly as tall as the line.
                let band = CGRect(x: min(first.x, last.x), y: first.y - a.amount / 2, width: abs(last.x - first.x), height: a.amount)
                ctx.setFillColor(a.color.nsColor.withAlphaComponent(0.32).cgColor)
                ctx.addPath(CGPath(roundedRect: band, cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.fillPath()
            } else {
                ctx.setStrokeColor(a.color.nsColor.withAlphaComponent(0.32).cgColor)
                ctx.setLineWidth(Self.highlighterWidth(w))
                ctx.setLineCap(.butt)
                ctx.addPath(Self.smoothPath(a.points))
                ctx.strokePath()
            }
        case .counter(let n):
            let counter = counter.resolved(for: a)
            let label = counter.style.label(counter.start + n - 1)
            let d = counter.diameter
            let width = max(d, Self.counterLabelWidth(label, diameter: d))
            let pill = CGRect(x: a.start.x - width / 2, y: a.start.y - d / 2, width: width, height: d)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: d / 2, cornerHeight: d / 2, transform: nil))
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0)
            let font = NSFont.rounded(size: d * 0.58, weight: .bold)
            Self.drawText(label, font: font, color: a.color.prefersWhiteText ? .white : .black, centeredIn: pill, ctx: ctx)
        case .text(let string):
            Self.drawStyledText(string, at: a.start, size: a.fontSize, color: a.color, style: TextStyle(variant: a.variant), ctx: ctx)
        case .redact, .spotlight:
            break
        }
    }

    private func drawRedact(_ a: Annotation, ctx: CGContext) {
        let r = a.rect.intersection(CGRect(origin: .zero, size: imageSize))
        guard !r.isEmpty else { return }
        let mode = RedactMode(rawValue: a.variant) ?? .pixelate
        ctx.saveGState()
        if mode == .blackOut {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(Self.roundedRect(r, radius: 3))
            ctx.fillPath()
        } else if let image = effects?.image(mode, amount: a.amount) {
            ctx.clip(to: r)
            Self.drawImage(image, in: CGRect(origin: .zero, size: imageSize), ctx: ctx)
        }
        ctx.restoreGState()
    }

    // MARK: Export

    /// Renders the final image at the screenshot's full pixel resolution.
    static func export(base: CGImage, imageSize: CGSize, effects: RedactEffects?, annotations: [Annotation],
                       background: BackgroundStyle? = nil, counter: CounterSettings = CounterSettings(),
                       images: [String: CGImage] = [:]) -> CGImage? {
        let scale = CGFloat(base.width) / imageSize.width
        let layout = background?.layout(for: imageSize) ?? BackgroundStyle.Layout(canvasSize: imageSize, imageOrigin: .zero)
        let width = Int((layout.canvasSize.width * scale).rounded()), height = Int((layout.canvasSize.height * scale).rounded())
        guard let ctx = ImageProcessing.context(width: width, height: height, colorSpace: base.colorSpace) else { return nil }
        // Flip to y-down document coordinates with the screenshot's top-left at the origin.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: layout.imageOrigin.x, y: layout.imageOrigin.y)
        var renderer = AnnotationRenderer(baseImage: base, imageSize: imageSize, effects: effects)
        renderer.background = background
        renderer.counter = counter
        renderer.images = images
        renderer.deviceScale = scale
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        renderer.draw(annotations, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Geometry helpers

    static func counterLabelWidth(_ label: String, diameter d: CGFloat) -> CGFloat {
        let size = (label as NSString).size(withAttributes: [.font: NSFont.rounded(size: d * 0.58, weight: .bold)])
        return size.width + d * 0.5
    }
    /// Broad marker: ~20pt at the default thickness, ~50pt at the largest.
    static func highlighterWidth(_ lineWidth: CGFloat) -> CGFloat { lineWidth * 2.8 }

    /// Band height of a highlighter stroke: the text line's height when snapped, else from the thickness.
    static func highlighterWidth(of a: Annotation) -> CGFloat { a.variant == 1 ? a.amount : highlighterWidth(a.lineWidth) }

    static func roundedRect(_ r: CGRect, radius: CGFloat) -> CGPath {
        let rad = min(radius, min(r.width, r.height) / 2)
        return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    }

    /// Tapered shaft (thin tail → full width) with a broad triangular head.
    static func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath {
        let dx = e.x - s.x, dy = e.y - s.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len          // along the arrow
        let px = -uy, py = ux                      // perpendicular
        let headLen = min(max(w * 3.6, 16), len * 0.9)
        let headHalf = max(w * 2.1, 9)
        let shaftEnd = len - headLen * 0.82
        let tailHalf = w * 0.18, neckHalf = w * 0.55
        func p(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: s.x + ux * along + px * across, y: s.y + uy * along + py * across)
        }
        let path = CGMutablePath()
        path.move(to: p(0, tailHalf))
        path.addLine(to: p(shaftEnd, neckHalf))
        path.addLine(to: p(len - headLen, headHalf))
        path.addLine(to: e)
        path.addLine(to: p(len - headLen, -headHalf))
        path.addLine(to: p(shaftEnd, -neckHalf))
        path.addLine(to: p(0, -tailHalf))
        path.closeSubpath()
        return path
    }

    /// Freehand smoothing: quadratic curves through the midpoints of the samples ("Smooth drawing"),
    /// or straight segments when smoothing is off.
    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2, Defaults[Prefs.annotateSmoothDrawing] else {
            pts.dropFirst().forEach { path.addLine(to: $0) }
            if pts.count == 1 { path.addLine(to: first) }
            return path
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.addLine(to: mid(pts[0], pts[1]))
        for i in 1..<(pts.count - 1) {
            path.addQuadCurve(to: mid(pts[i], pts[i + 1]), control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    // MARK: Arrows

    static func drawArrow(_ a: Annotation, style: ArrowStyle, color: CGColor, width w: CGFloat, ctx: CGContext) {
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        switch style {
        case .standard:
            ctx.setLineWidth(1.5)
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: w))
            ctx.drawPath(using: .fillStroke)
        case .fancy:
            // Swept-back head on a tapered shaft.
            ctx.setLineWidth(1)
            ctx.addPath(fancyArrowPath(from: a.start, to: a.end, width: w))
            ctx.drawPath(using: .fillStroke)
        case .curved, .double:
            // Straight until the middle handle is dragged; then a curve through that point.
            let control = a.curveControl
            let headLen = max(w * 3.2, 14)
            // Stop the curve where a head begins, aiming along the tangent at that end.
            func neck(_ tip: CGPoint) -> CGPoint {
                let tx = tip.x - control.x, ty = tip.y - control.y, tl = max(hypot(tx, ty), 0.001)
                return CGPoint(x: tip.x - tx / tl * headLen * 0.8, y: tip.y - ty / tl * headLen * 0.8)
            }
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.move(to: style == .double ? neck(a.start) : a.start)
            ctx.addQuadCurve(to: neck(a.end), control: control)
            ctx.strokePath()
            ctx.setLineWidth(1.5)
            ctx.addPath(headPath(tip: a.end, from: control, width: w))
            if style == .double { ctx.addPath(headPath(tip: a.start, from: control, width: w)) }
            ctx.drawPath(using: .fillStroke)
        }
    }

    /// Triangular head at `tip`, pointing away from `from`.
    static func headPath(tip: CGPoint, from: CGPoint, width w: CGFloat) -> CGPath {
        let dx = tip.x - from.x, dy = tip.y - from.y, len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len, px = -uy, py = ux
        let headLen = max(w * 3.2, 14), half = max(w * 1.9, 8)
        let base = CGPoint(x: tip.x - ux * headLen, y: tip.y - uy * headLen)
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + px * half, y: base.y + py * half))
        path.addLine(to: CGPoint(x: base.x - px * half, y: base.y - py * half))
        path.closeSubpath()
        return path
    }

    static func fancyArrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> CGPath {
        let dx = e.x - s.x, dy = e.y - s.y, len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len, px = -uy, py = ux
        let headLen = min(max(w * 4.2, 18), len * 0.9), headHalf = max(w * 2.3, 10)
        func p(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: s.x + ux * along + px * across, y: s.y + uy * along + py * across)
        }
        let path = CGMutablePath()
        path.move(to: s)
        path.addLine(to: p(len - headLen * 0.62, w * 0.45))
        path.addLine(to: p(len - headLen, headHalf))
        path.addLine(to: e)
        path.addLine(to: p(len - headLen, -headHalf))
        path.addLine(to: p(len - headLen * 0.62, -w * 0.45))
        path.closeSubpath()
        return path
    }

    // MARK: Text

    /// Draws text in one of the text styles; returns nothing, bounds come from `styledTextSize`. `backgroundOnly`
    /// draws just the box or white outline (behind the letters of the text being typed).
    static func drawStyledText(_ string: String, at origin: CGPoint, size: CGFloat, color: AnnotationColor, style: TextStyle,
                               backgroundOnly: Bool = false, ctx: CGContext) {
        let font = style.font(size: size)
        let textSize = styledTextSize(string, size: size, style: style)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.textColor(color)]
        var textOrigin = origin
        if style.hasBox {
            let pad = boxPadding(size)
            let box = CGRect(origin: origin, size: textSize)
            let radius = size * (style == .card ? 0.28 : 0.18)
            switch style {
            case .card:
                // White card, colored border inside the box (light gray for white).
                let border = max(1.5, size * 0.08)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
                (color.hex == 0xFFFFFF ? NSColor(white: 0.8, alpha: 1) : color.nsColor).setStroke()
                let edge = NSBezierPath(roundedRect: box.insetBy(dx: border / 2, dy: border / 2), xRadius: radius - border / 2, yRadius: radius - border / 2)
                edge.lineWidth = border
                edge.stroke()
            case .code:
                NSColor(white: 0.11, alpha: 0.92).setFill()
                NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            default:
                color.nsColor.setFill()
                NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            }
            textOrigin = CGPoint(x: origin.x + pad.width, y: origin.y + pad.height)
            if backgroundOnly { NSGraphicsContext.restoreGraphicsState(); return }
        } else if style == .outline {
            // Colored letters with a white outline.
            let outline = attrs.merging([.strokeColor: NSColor.white, .strokeWidth: 12, .foregroundColor: NSColor.white]) { $1 }
            (string as NSString).draw(with: CGRect(origin: textOrigin, size: textSize), options: [.usesLineFragmentOrigin], attributes: outline)
            if backgroundOnly { NSGraphicsContext.restoreGraphicsState(); return }
        }
        (string as NSString).draw(with: CGRect(origin: textOrigin, size: textSize), options: [.usesLineFragmentOrigin], attributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func boxPadding(_ size: CGFloat) -> CGSize { CGSize(width: size * 0.35, height: size * 0.12) }

    static func styledTextSize(_ string: String, size: CGFloat, style: TextStyle) -> CGSize {
        let s = (string.isEmpty ? " " : string) as NSString
        let r = s.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
                               attributes: [.font: style.font(size: size)])
        var result = CGSize(width: ceil(r.width), height: ceil(r.height))
        if style.hasBox {
            let pad = boxPadding(size)
            result.width += pad.width * 2
            result.height += pad.height * 2
        }
        return result
    }

    static func textAttributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.rounded(size: size, weight: .bold), .foregroundColor: color]
    }

    static func textSize(_ string: String, size: CGFloat) -> CGSize {
        let s = (string.isEmpty ? " " : string) as NSString
        let r = s.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin],
                               attributes: textAttributes(size: size, color: .white))
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }

    static func drawText(_ string: String, at origin: CGPoint, size: CGFloat, color: NSColor, ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (string as NSString).draw(with: CGRect(origin: origin, size: textSize(string, size: size)),
                                  options: [.usesLineFragmentOrigin], attributes: textAttributes(size: size, color: color))
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawText(_ string: String, font: NSFont, color: NSColor, centeredIn rect: CGRect, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (string as NSString).size(withAttributes: attrs)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        (string as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws a CGImage upright in a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }
}

extension NSFont {
    /// SF Pro Rounded, used for text and counters.
    static func rounded(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// Soft-edged clip masks for spotlights (white = painted), at half resolution; the last few are kept, since the
/// canvas redraws often with the same spotlights.
final class SpotMask: @unchecked Sendable {
    static let shared = SpotMask()
    private let lock = NSLock()
    private var cache: [(path: CGPath, size: CGSize, edge: CGFloat, inside: Bool, image: CGImage)] = []

    func mask(_ spots: CGPath, size: CGSize, edge: CGFloat, inside: Bool) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache.first(where: { $0.path == spots && $0.size == size && $0.edge == edge && $0.inside == inside }) { return hit.image }
        let scale: CGFloat = 0.5
        let w = max(Int(ceil(size.width * scale)), 1), h = max(Int(ceil(size.height * scale)), 1)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: inside ? 0 : 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // y-down like the document; the spotlights are filled far to the left and only their blurred shadow lands
        // here, so the edge fades evenly to both sides of the outline.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let away = size.width + edge * 4 + 100
        ctx.setShadow(offset: CGSize(width: away * scale, height: 0), blur: edge * scale,
                      color: CGColor(gray: inside ? 1 : 0, alpha: 1))
        ctx.translateBy(x: -away, y: 0)
        ctx.addPath(spots)
        ctx.fillPath()
        guard let image = ctx.makeImage() else { return nil }
        cache.insert((spots.copy() ?? spots, size, edge, inside, image), at: 0)
        if cache.count > 4 { cache.removeLast() }
        return image
    }
}
