import AppKit
import CoreImage

/// Backdrop behind a screenshot (the Annotate "Background" tool and the automatic background preset).
struct BackgroundStyle: Codable, Equatable {
    enum Fill: Codable, Equatable {
        case gradient(Int)
        case wallpaper
        case customImage(String)
        case blurred(Int)
        case color(UInt32)
        case transparent
    }

    enum Ratio: String, Codable, CaseIterable, Identifiable {
        case auto, square, r4x3, r3x2, r16x9, r16x10, r9x16
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Auto"
            case .square: "1:1"
            case .r4x3: "4:3"
            case .r3x2: "3:2"
            case .r16x9: "16:9"
            case .r16x10: "16:10"
            case .r9x16: "9:16"
            }
        }
        var value: CGFloat? {
            switch self {
            case .auto: nil
            case .square: 1
            case .r4x3: 4.0 / 3
            case .r3x2: 3.0 / 2
            case .r16x9: 16.0 / 9
            case .r16x10: 16.0 / 10
            case .r9x16: 9.0 / 16
            }
        }
    }

    var fill: Fill
    /// Slider values 0…1, mapped to points in `layout`.
    var padding: CGFloat = 0
    var inset: CGFloat = 0
    var autoBalance = false
    var shadow: CGFloat = 0
    var corners: CGFloat = 0
    /// The backdrop's brightness (0.5…1.5; nil = 1, unchanged), and how blurred a wallpaper or image backdrop is
    /// (0 none, 1 light, 2 medium, 3 strong; nil = 0). Optional so older presets still decode.
    var brightness: CGFloat?
    var blur: Int?
    /// 0…8, row-major 3×3 grid; 4 is centered.
    var alignment = 4
    var ratio: Ratio = .auto
    /// "Automatically expand canvas": extra room on each side so annotations past the canvas edge fit (points).
    /// Set by the document, never by the Background tool; optional so older saved presets still decode.
    var expansion: Insets?
    /// A saved preset's name (nil on the document's own background).
    var name: String?

    struct Insets: Codable, Equatable {
        var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
        var isZero: Bool { top == 0 && left == 0 && bottom == 0 && right == 0 }
    }

    static let maxPadding: CGFloat = 300
    // The slider ranges: padding 0–300pt, inset 0–100pt, shadow 0–100, corners 0–60
    // (corners = % of half the card's shorter side, i.e. how far the corner circle's center moves toward the middle).
    static let maxInset: CGFloat = 100
    static let maxCornerPercent: CGFloat = 60
    static let maxShadow: CGFloat = 100

    struct Layout {
        let canvasSize: CGSize
        /// Where the screenshot's top-left sits on the canvas.
        let imageOrigin: CGPoint
    }

    func layout(for image: CGSize) -> Layout {
        let pad = padding * Self.maxPadding
        let ins = inset * Self.maxInset
        let content = CGSize(width: image.width + ins * 2, height: image.height + ins * 2)
        // Canvas = card + padding on every side (expanded to a fixed ratio if chosen). Alignment only slides the card
        // across the free space until its edge meets the canvas edge; the sizes stay the same.
        var canvas = CGSize(width: content.width + pad * 2, height: content.height + pad * 2)
        if let r = ratio.value {
            if canvas.width / canvas.height < r { canvas.width = canvas.height * r } else { canvas.height = canvas.width / r }
        }
        let fx = CGFloat(alignment % 3) / 2, fy = CGFloat(alignment / 3) / 2
        let freeX = canvas.width - content.width, freeY = canvas.height - content.height
        let e = expansion ?? Insets()
        canvas.width += e.left + e.right
        canvas.height += e.top + e.bottom
        // Exact (unrounded) values: rounding made the canvas jitter against the window edge while dragging sliders.
        return Layout(canvasSize: canvas, imageOrigin: CGPoint(x: freeX * fx + ins + e.left, y: freeY * fy + ins + e.top))
    }

    // MARK: Presets

    static var presets: [BackgroundStyle] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "background.presets") else { return [] }
            return (try? JSONDecoder().decode([BackgroundStyle].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "background.presets") }
    }

    /// Last background used in the editor (for "Remember if background tool was opened").
    static var lastUsed: BackgroundStyle? {
        get { UserDefaults.standard.data(forKey: "background.last").flatMap { try? JSONDecoder().decode(BackgroundStyle.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "background.last") }
    }
}

/// Glint's gradient and color swatches (its own set).
enum BackgroundPalette {
    static let linear: [[UInt32]] = [
        [0x1E3C72, 0xF7B267], [0xFF61D2, 0x6A82FB, 0x2BD2FF], [0xFC466B, 0x3F5EFB, 0xFDBB2D],
        [0xF5576C, 0x8E44AD], [0x667EEA, 0x9F7AEA], [0x0F2C67, 0x3A7BD5], [0x43E3B0, 0x2AA8A0], [0xFFB199, 0xFF6A6A],
        [0xF2E6EE, 0xC9D6DF], [0xE2D1C3, 0xB8C6DB], [0x7F7FD5, 0x86A8E7, 0x91EAE4], [0x0B0B2B, 0x3A1C71],
        [0xA1C4FD, 0xE0C3FC], [0xD9A7C7, 0x8E9EEB, 0xFFFCDC], [0x5B0E2D, 0xC33764], [0x1D2671, 0xC33764],
        [0xDA22FF, 0x9733EE, 0xF7797D], [0xFF512F, 0xF09819], [0x2B0A0A, 0xCB2D3E], [0xEE9CA7, 0xFFDDE1],
    ]

    /// Mesh-like gradients: a base color with soft colored blobs (x, y, radius as fractions of the canvas).
    struct Blob { let x, y, r: CGFloat; let color: UInt32 }
    static let blobs: [(base: UInt32, blobs: [Blob])] = [
        (0x1B1446, [Blob(x: 0.15, y: 0.2, r: 0.7, color: 0xFF5E8A), Blob(x: 0.85, y: 0.3, r: 0.6, color: 0x5B6CFF), Blob(x: 0.5, y: 1.0, r: 0.7, color: 0xFFB24D)]),
        (0x0E2A47, [Blob(x: 0.0, y: 1.0, r: 0.9, color: 0x22D3B6), Blob(x: 0.9, y: 0.1, r: 0.7, color: 0x7B5CFF)]),
        (0xFFE3D3, [Blob(x: 0.2, y: 0.8, r: 0.7, color: 0xFF8FB1), Blob(x: 0.8, y: 0.2, r: 0.6, color: 0xFFC56B), Blob(x: 0.6, y: 0.7, r: 0.4, color: 0xB89CFF)]),
        (0x06121F, [Blob(x: 0.3, y: 0.4, r: 0.55, color: 0x2E6BFF), Blob(x: 0.75, y: 0.75, r: 0.55, color: 0xC042FF)]),
        (0xF6F1FF, [Blob(x: 0.1, y: 0.1, r: 0.6, color: 0xA7C7FF), Blob(x: 0.9, y: 0.9, r: 0.7, color: 0xFFB8E1)]),
        (0x2A0A12, [Blob(x: 0.5, y: 0.0, r: 0.8, color: 0xFF4D3D), Blob(x: 0.2, y: 1.0, r: 0.6, color: 0xFF9A3D), Blob(x: 0.9, y: 0.8, r: 0.5, color: 0x8F1D5C)]),
        (0x0B3B2E, [Blob(x: 0.8, y: 0.2, r: 0.7, color: 0xB7F06A), Blob(x: 0.15, y: 0.85, r: 0.6, color: 0x1FB5A8)]),
        (0x14102B, [Blob(x: 0.5, y: 0.5, r: 0.5, color: 0xFF6FD8), Blob(x: 0.0, y: 0.0, r: 0.6, color: 0x3813C2), Blob(x: 1.0, y: 1.0, r: 0.6, color: 0x2DD4FF)]),
        (0xFFF4E0, [Blob(x: 0.0, y: 0.5, r: 0.7, color: 0xFF7A59), Blob(x: 1.0, y: 0.4, r: 0.7, color: 0x6C8CFF)]),
        (0x101418, [Blob(x: 0.7, y: 0.3, r: 0.6, color: 0x5A6B7D), Blob(x: 0.2, y: 0.8, r: 0.5, color: 0x2C3A47)]),
    ]

    static var count: Int { linear.count + blobs.count }

    /// Panel order: by dominant hue (grays last), and within a hue from subtle to strong gradients.
    private static let order: [Int] = {
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        func colors(_ raw: Int) -> [(UInt32, CGFloat)] {
            raw < linear.count ? linear[raw].map { ($0, 1) } : [(blobs[raw - linear.count].base, 1)] + blobs[raw - linear.count].blobs.map { ($0.color, 0.7) }
        }
        func key(_ raw: Int) -> (Int, CGFloat) {
            let cs = colors(raw)
            var hx: CGFloat = 0, hy: CGFloat = 0, wsum: CGFloat = 0
            var mean = (CGFloat(0), CGFloat(0), CGFloat(0))
            for (hex, w) in cs {
                let ns = NSColor(srgbRed: rgb(hex).0, green: rgb(hex).1, blue: rgb(hex).2, alpha: 1)
                let angle = ns.hueComponent * 2 * .pi, sat = ns.saturationComponent * ns.brightnessComponent
                hx += cos(angle) * sat * w; hy += sin(angle) * sat * w; wsum += w
                mean.0 += rgb(hex).0 * w; mean.1 += rgb(hex).1 * w; mean.2 += rgb(hex).2 * w
            }
            mean = (mean.0 / wsum, mean.1 / wsum, mean.2 / wsum)
            let spread = cs.map { hex, _ in
                let c = rgb(hex); return sqrt(pow(c.0 - mean.0, 2) + pow(c.1 - mean.1, 2) + pow(c.2 - mean.2, 2))
            }.max() ?? 0
            let chroma = hypot(hx, hy) / wsum
            guard chroma > 0.12 else { return (99, spread) }  // grays and balanced mixes go last
            var hue = atan2(hy, hx) / (2 * .pi); if hue < 0 { hue += 1 }
            // Start at red-pink (hue ≈ 0.94) so pinks and reds stay together.
            let shifted = (hue + 0.06).truncatingRemainder(dividingBy: 1)
            return (Int(shifted * 8), spread)
        }
        return (0..<count).sorted { key($0) < key($1) }
    }()

    private static func entry(_ index: Int) -> (linear: [UInt32]?, blob: Int?) {
        let raw = order[min(max(index, 0), count - 1)]
        return raw < linear.count ? (linear[raw], nil) : (nil, raw - linear.count)
    }

    static func drawGradient(_ index: Int, in rect: CGRect, ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.displayP3)
        let e = entry(index)
        if let stops = e.linear {
            let colors = stops.map { nsColor($0).cgColor } as CFArray
            if let g = CGGradient(colorsSpace: space, colors: colors, locations: nil) {
                ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
            }
        } else if let b = e.blob {
            let spec = blobs[b]
            ctx.setFillColor(nsColor(spec.base).cgColor)
            ctx.fill(rect)
            let size = max(rect.width, rect.height)
            for blob in spec.blobs {
                let c = nsColor(blob.color)
                let colors = [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray
                guard let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
                let center = CGPoint(x: rect.minX + blob.x * rect.width, y: rect.minY + blob.y * rect.height)
                ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: blob.r * size, options: [])
            }
        }
    }

    private static var swatchCache: [Int: NSImage] = [:]
    static func swatch(_ index: Int) -> NSImage {
        if let cached = swatchCache[index] { return cached }
        let image = NSImage(size: NSSize(width: 38, height: 38), flipped: true) { rect in
            if let ctx = NSGraphicsContext.current?.cgContext { drawGradient(index, in: rect, ctx: ctx) }
            return true
        }
        swatchCache[index] = image
        return image
    }

    static let colorsDark: [UInt32] = [0x111111, 0xFFFFFF, 0xE5484A, 0xF09235, 0xF5B83D, 0x3EA55D, 0x3478F6, 0x8254F6]
    static let colorsLight: [UInt32] = [0x4A4A4A, 0xE6E6E6, 0xF7B0B1, 0xF8C99B, 0xFBE3A4, 0xB6E3BE, 0xB4CDF9, 0xD3C2FA]

    static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(displayP3Red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Wallpaper-based fills, prepared once and cached.
final class BackgroundImages {
    static let shared = BackgroundImages()
    private(set) var wallpaper: CGImage?
    private var blurred: [Int: CGImage] = [:]
    private var custom: [String: CGImage] = [:]
    private var softened: [String: CGImage] = [:]

    /// A wallpaper or image backdrop blurred `level` (1 light … 3 strong; 0 = as it is).
    func image(for fill: BackgroundStyle.Fill, blur level: Int) -> CGImage? {
        guard level > 0, let image = image(for: fill) else { return image(for: fill) }
        let key = "\(fill)-\(level)"
        if let cached = softened[key] { return cached }
        let input = CIImage(cgImage: image)
        let sigma = Double(max(image.width, image.height)) / [0, 160, 70, 30][min(level, 3)]
        let output = input.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: input.extent)
        let result = CIContext().createCGImage(output, from: input.extent)
        softened[key] = result
        return result
    }

    /// The macOS wallpapers stored on this Mac as pictures (the dynamic ones are downloaded on demand), with their
    /// small preview.
    static let builtInWallpapers: [(path: String, thumbnail: String)] = {
        let dir = "/System/Library/Desktop Pictures"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return files.filter { $0.hasSuffix(".heic") || $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }.sorted().map { name in
            let thumb = "\(dir)/.thumbnails/\(name)"
            return ("\(dir)/\(name)", FileManager.default.fileExists(atPath: thumb) ? thumb : "\(dir)/\(name)")
        }
    }()

    /// A small preview of a picture file (wallpaper menu).
    private var thumbnails: [String: CGImage] = [:]
    func thumbnail(_ path: String) -> CGImage? {
        if let cached = thumbnails[path] { return cached }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
        else { return nil }
        thumbnails[path] = image
        return image
    }

    func prepare() async {
        guard wallpaper == nil, let screen = NSScreen.main else { return }
        wallpaper = await WallpaperProvider.image(for: screen)
    }

    func image(for fill: BackgroundStyle.Fill) -> CGImage? {
        switch fill {
        case .wallpaper: return wallpaper
        case .customImage(let path):
            if let cached = custom[path] { return cached }
            let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            custom[path] = image
            return image
        case .blurred(let variant):
            if let cached = blurred[variant] { return cached }
            guard let wallpaper else { return nil }
            let image = Self.blur(wallpaper, darken: [0, 0.35, 0.65][min(max(variant, 0), 2)])
            blurred[variant] = image
            return image
        default: return nil
        }
    }

    private static func blur(_ image: CGImage, darken: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(max(image.width, image.height)) / 40)
            .cropped(to: input.extent)
        let dimmed = darken > 0
            ? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: darken)).cropped(to: input.extent).composited(over: blurred)
            : blurred
        return CIContext().createCGImage(dimmed, from: input.extent)
    }
}

extension BackgroundStyle {
    /// Draws the backdrop and the screenshot's frame (shadow, inset, rounded corners) in a y-down context
    /// whose origin is the screenshot's top-left.
    func drawBackdrop(imageSize: CGSize, baseImage: CGImage, ctx: CGContext, deviceScale: CGFloat, gridCell: CGFloat? = nil) {
        let layout = layout(for: imageSize)
        let canvas = CGRect(origin: CGPoint(x: -layout.imageOrigin.x, y: -layout.imageOrigin.y), size: layout.canvasSize)
        ctx.saveGState()
        ctx.clip(to: canvas)
        switch fill {
        case .gradient(let index):
            BackgroundPalette.drawGradient(index, in: canvas, ctx: ctx)
        case .color(let hex):
            ctx.setFillColor(BackgroundPalette.nsColor(hex).cgColor)
            ctx.fill(canvas)
        case .transparent:
            if let gridCell { Self.drawChecker(in: canvas, cell: gridCell, ctx: ctx) }
        default:
            if let image = BackgroundImages.shared.image(for: fill, blur: blur ?? 0) {
                let iw = CGFloat(image.width), ih = CGFloat(image.height)
                let s = max(canvas.width / iw, canvas.height / ih)
                AnnotationRenderer.drawImage(image, in: CGRect(x: canvas.midX - iw * s / 2, y: canvas.midY - ih * s / 2, width: iw * s, height: ih * s), ctx: ctx)
            }
        }
        // Brightness: darker toward black, brighter toward white.
        if fill != .transparent, let b = brightness, abs(b - 1) > 0.005 {
            ctx.setFillColor(b < 1 ? CGColor(gray: 0, alpha: min(1 - b, 1)) : CGColor(gray: 1, alpha: min(b - 1, 1)))
            ctx.fill(canvas)
        }

        let ins = inset * Self.maxInset
        let card = CGRect(origin: .zero, size: imageSize).insetBy(dx: -ins, dy: -ins)
        let radii = cornerRadii(imageSize: imageSize)
        let cardPath = Self.cornerPath(card, radii: radii)
        for layer in BackgroundShadow.layers(shadow) {
            // SoftShape's blur is twice the Gaussian sigma.
            if let (image, rect) = SoftShape.image(card: card, radii: radii, color: NSColor.black.withAlphaComponent(layer.opacity).cgColor,
                                                   blur: layer.sigma * 2) {
                AnnotationRenderer.drawImage(image, in: rect.offsetBy(dx: 0, dy: layer.offset), ctx: ctx)
            }
        }
        // Auto-balance: the inset's edge color fades smoothly into the background outside the card.
        if autoBalance, fill != .transparent {  // nothing to blend into when there's no background
            let reach = max(padding * Self.maxPadding * 0.6, 30)
            if let (image, rect) = SoftShape.image(card: card, radii: radii, color: Self.edgeColor(of: baseImage), blur: reach) {
                AnnotationRenderer.drawImage(image, in: rect, ctx: ctx)
                AnnotationRenderer.drawImage(image, in: rect, ctx: ctx)
            }
        }
        // Inset area is filled with the screenshot's own edge color.
        if ins > 0 {
            ctx.addPath(cardPath)
            ctx.setFillColor(Self.edgeColor(of: baseImage))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    /// The screenshot is clipped by the card's outer shape (not a smaller concentric one), so a large inset
    /// keeps the screenshot whole while the card corners are strongly rounded.
    func clipScreenshot(imageSize: CGSize, ctx: CGContext) {
        let radii = cornerRadii(imageSize: imageSize)
        guard radii.contains(where: { $0 > 0 }) else { return }
        let ins = inset * Self.maxInset
        ctx.addPath(Self.cornerPath(CGRect(origin: .zero, size: imageSize).insetBy(dx: -ins, dy: -ins), radii: radii))
        ctx.clip()
    }

    /// Card corner radii (top-left, top-right, bottom-right, bottom-left).
    /// The radius depends only on the Corners slider (inset just moves the same-sized corners apart). At full corners it
    /// is chosen so that with full inset the arc's midpoint exactly touches the screenshot's corner:
    /// depth r·(1−1/√2) = 100pt → r ≈ 341pt. Capped at half the card's shorter side. Corners at a wall stay square.
    static let maxRadius: CGFloat = maxInset / (1 - 1 / 2.squareRoot())

    func cornerRadii(imageSize size: CGSize) -> [CGFloat] {
        let ins = inset * Self.maxInset
        let card = CGSize(width: size.width + ins * 2, height: size.height + ins * 2)
        let r = max(0, min(corners * Self.maxRadius, min(card.width, card.height) / 2))
        guard padding > 0 else { return [r, r, r, r] }
        let col = alignment % 3, row = alignment / 3
        let left = col == 0, right = col == 2, top = row == 0, bottom = row == 2
        return [(top || left) ? 0 : r, (top || right) ? 0 : r, (bottom || right) ? 0 : r, (bottom || left) ? 0 : r]
    }

    /// macOS-style dark transparency grid (#313131 / #494949, 10pt cells on screen), anchored to the canvas's
    /// bottom edge so growing padding only adds rows at the top. No antialiasing, so no seams between cells.
    static func drawChecker(in rect: CGRect, cell: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShouldAntialias(false)
        ctx.setFillColor(BackgroundPalette.nsColor(0x313131).cgColor)
        ctx.fill(rect)
        ctx.setFillColor(BackgroundPalette.nsColor(0x494949).cgColor)
        var row = 0
        var y = rect.maxY - cell  // y-down: start at the bottom edge
        while y > rect.minY - cell {
            var x = rect.minX + (row.isMultiple(of: 2) ? cell : 0)
            while x < rect.maxX { ctx.fill(CGRect(x: x, y: y, width: cell, height: cell).intersection(rect)); x += cell * 2 }
            y -= cell; row += 1
        }
        ctx.restoreGState()
    }

    /// Rounded rect with individual corner radii in a y-down context.
    static func cornerPath(_ r: CGRect, radii: [CGFloat]) -> CGPath {
        let p = CGMutablePath()
        let tl = radii[0], tr = radii[1], br = radii[2], bl = radii[3]
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        if tr > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + tr), radius: tr) }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        if br > 0 { p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - br, y: r.maxY), radius: br) }
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        if bl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - bl), radius: bl) }
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        if tl > 0 { p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + tl, y: r.minY), radius: tl) }
        p.closeSubpath()
        return p
    }

    private static var edgeColorCache: [(image: CGImage, color: CGColor)] = []

    /// Most common color of the screenshot's outermost pixel ring.
    static func edgeColor(of image: CGImage) -> CGColor {
        if let cached = edgeColorCache.first(where: { $0.image === image }) { return cached.color }
        let w = image.width, h = image.height
        guard w > 2, h > 2, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSColor.white.cgColor }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return NSColor.white.cgColor }
        // Vote over a 3px ring with coarse buckets, then average the exact pixels of the winning bucket:
        // the color covering most of the edge wins, never a blend of different colors.
        var buckets: [UInt32: (n: Int, r: Int, g: Int, b: Int)] = [:]
        func add(_ x: Int, _ y: Int) {
            let o = (y * w + x) * 4
            let r = Int(p[o]), g = Int(p[o + 1]), b = Int(p[o + 2])
            let key = UInt32(r >> 4) << 8 | UInt32(g >> 4) << 4 | UInt32(b >> 4)
            let e = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (e.n + 1, e.r + r, e.g + g, e.b + b)
        }
        let depth = min(3, w / 2, h / 2)
        for d in 0..<depth {
            for x in d..<(w - d) { add(x, d); add(x, h - 1 - d) }
            for y in (d + 1)..<(h - 1 - d) { add(d, y); add(w - 1 - d, y) }
        }
        let best = buckets.values.max { $0.n < $1.n } ?? (1, 255, 255, 255)
        let color = CGColor(srgbRed: CGFloat(best.r) / CGFloat(best.n * 255), green: CGFloat(best.g) / CGFloat(best.n * 255),
                            blue: CGFloat(best.b) / CGFloat(best.n * 255), alpha: 1)
        if edgeColorCache.count > 8 { edgeColorCache.removeFirst() }
        edgeColorCache.append((image, color))
        return color
    }
}

/// Soft (blurred) card silhouette for shadow and Auto-balance, rendered at quarter resolution and cached,
/// so dragging sliders doesn't redo large full-resolution blurs on every frame.
/// The Background shadow: two soft black layers, a tight one and a wide one, both shifted down (fitted to a
/// reference look at slider 25/50/100% on a 1200×800pt card). They grow faster than the slider, so the values are interpolated between the measured steps. Points.
enum BackgroundShadow {
    struct Layer { let opacity: CGFloat; let sigma: CGFloat; let offset: CGFloat }

    private static let steps: [(CGFloat, Layer, Layer)] = [
        (0, Layer(opacity: 0, sigma: 0, offset: 0), Layer(opacity: 0, sigma: 0, offset: 0)),
        (0.25, Layer(opacity: 0.212, sigma: 6.2, offset: 6.9), Layer(opacity: 0.159, sigma: 18.9, offset: 24.3)),
        (0.5, Layer(opacity: 0.299, sigma: 11.0, offset: 13.7), Layer(opacity: 0.322, sigma: 36.5, offset: 48.4)),
        (1, Layer(opacity: 0.495, sigma: 18.9, offset: 22.7), Layer(opacity: 0.81, sigma: 104.1, offset: 88.1)),
    ]

    /// The card size the steps were measured on (the video editor scales the shadow by its card's shorter side).
    static let measuredShortSide: CGFloat = 800

    /// The layers for a slider value 0…1 (none at 0).
    static func layers(_ value: CGFloat) -> [Layer] {
        let v = min(max(value, 0), 1)
        guard v > 0, let upper = steps.firstIndex(where: { $0.0 >= v }) else { return [] }
        let lo = steps[max(upper - 1, 0)], hi = steps[upper]
        let t = hi.0 == lo.0 ? 1 : (v - lo.0) / (hi.0 - lo.0)
        func mix(_ a: Layer, _ b: Layer) -> Layer {
            Layer(opacity: a.opacity + (b.opacity - a.opacity) * t, sigma: max(a.sigma + (b.sigma - a.sigma) * t, 0.5),
                  offset: a.offset + (b.offset - a.offset) * t)
        }
        return [mix(lo.1, hi.1), mix(lo.2, hi.2)]
    }
}

enum SoftShape {
    private static var cache: [String: (CGImage, CGRect)] = [:]
    private static let context = CIContext()

    static func image(card: CGRect, radii: [CGFloat], color: CGColor, blur: CGFloat) -> (CGImage, CGRect)? {
        let key = "\(card)\(radii)\(color)\(Int(blur))"
        if let hit = cache[key] { return hit }
        let scale: CGFloat = 0.25
        let rect = card.insetBy(dx: -blur * 1.5 - 4, dy: -blur * 1.5 - 4)
        let w = max(1, Int(rect.width * scale)), h = max(1, Int(rect.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // y-down drawing in rect coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.addPath(BackgroundStyle.cornerPath(card, radii: radii))
        ctx.setFillColor(color)
        ctx.fillPath()
        guard let sharp = ctx.makeImage() else { return nil }
        let input = CIImage(cgImage: sharp)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(blur * scale / 2)).cropped(to: input.extent)
        guard let image = context.createCGImage(blurred, from: input.extent) else { return nil }
        if cache.count > 12 { cache.removeAll() }
        cache[key] = (image, rect)
        return (image, rect)
    }
}
