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
