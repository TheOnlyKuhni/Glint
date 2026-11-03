import AppKit

/// Tool picker glyphs: SF Symbols as template images (tinted by the picker).
enum ToolGlyph {
    static func image(for tool: AnnotateTool) -> NSImage { images[tool] ?? NSImage() }

    private static let images: [AnnotateTool: NSImage] = Dictionary(uniqueKeysWithValues: AnnotateTool.allCases.map { ($0, make($0)) })

    static func symbolName(for tool: AnnotateTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .rectangle: "square"
        case .filledRectangle: "square.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.down.left"
        case .text: "character"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "rectangle.center.inset.filled"
        case .counter: "1.circle.fill"
        case .emoji: "face.smiling"
        case .draw: "pencil"
        case .highlighter: "highlighter"
        }
    }

    private static func make(_ tool: AnnotateTool) -> NSImage {
        let image = NSImage(systemSymbolName: symbolName(for: tool), accessibilityDescription: tool.title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// An emoji drawn into an image (4× its point size, so it stays sharp when enlarged).
enum EmojiImage {
    static func render(_ emoji: String, points: CGFloat) -> CGImage? {
        let pixels = Int(min(max(points * 4, 64), 1024))
        let font = NSFont(name: "Apple Color Emoji", size: CGFloat(pixels) * 0.82) ?? .systemFont(ofSize: CGFloat(pixels) * 0.82)
        let text = NSAttributedString(string: emoji, attributes: [.font: font])
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let size = text.size()
        text.draw(at: CGPoint(x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
