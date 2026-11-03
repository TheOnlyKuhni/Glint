import AppKit
import SwiftUI

/// Tool selector for the Annotate toolbar: a 24pt capsule of 35pt cells with 1pt separators.
/// The selected tool is a full-cell blue capsule (gray while the window is inactive); hovering shows a faint one.
/// Separators next to either disappear. Selection changes without animation. While cropping the tools rest: none is
/// selected and they're dimmed and off until Crop & Resize ends.
struct ToolPicker: View {
    let doc: AnnotationDocument
    let onSelect: (AnnotateTool) -> Void
    @State private var hovered: AnnotateTool?
    @Environment(\.controlActiveState) private var windowState

    static let cellWidth: CGFloat = 35
    private static let selectedFill = Color(.displayP3, red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)
    private static let glyph = Color(.displayP3, red: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0)

    var body: some View {
        let tools = AnnotateTool.allCases
        let inactive = windowState == .inactive
        let resting = doc.isCropping || doc.toolsResting
        HStack(spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                if index > 0 {
                    let highlighted: Set<AnnotateTool> = [resting ? nil : doc.tool, hovered].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
                    let hidden = highlighted.contains(tool) || highlighted.contains(tools[index - 1])
                    Rectangle()
                        .fill(Color.white.opacity(hidden ? 0 : 0.1))
                        .frame(width: 1, height: 14)
                }
                let selected = !resting && tool == doc.tool
                Button { onSelect(tool) } label: {
                    Image(nsImage: ToolGlyph.image(for: tool))
                        .foregroundStyle(inactive ? Color.white.opacity(0.65) : (selected ? Color.white : Self.glyph))
                        .frame(width: Self.cellWidth, height: 24)
                        .background(Capsule().fill(selected ? (inactive ? Color.white.opacity(0.2) : Self.selectedFill)
                                                            : Color.white.opacity(hovered == tool ? 0.12 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 && !resting ? tool : (hovered == tool ? nil : hovered) }
            }
        }
        .background(Capsule().fill(Color.white.opacity(0.1)))
        .opacity(resting ? 0.4 : 1)
        .allowsHitTesting(!resting)
        .animation(.easeOut(duration: 0.15), value: resting)
    }
}

/// Hosts the picker and registers a native tooltip for each tool (shown after the usual hover delay).
final class ToolPickerHostingView: NSHostingView<ToolPicker> {
    private var tooltipBounds: CGRect = .zero

    /// Only re-register when the size changes; re-registering on every hover redraw dismissed the hint.
    override func layout() {
        super.layout()
        guard bounds != tooltipBounds else { return }
        tooltipBounds = bounds
        removeAllToolTips()
        for (i, tool) in AnnotateTool.allCases.enumerated() {
            let x = CGFloat(i) * (ToolPicker.cellWidth + 1)
            addToolTip(CGRect(x: x, y: 0, width: ToolPicker.cellWidth, height: bounds.height), owner: ToolHint(tool: tool), userData: nil)
        }
    }

    private var hints: [ToolHint] = []

    override func addToolTip(_ rect: NSRect, owner: Any, userData data: UnsafeMutableRawPointer?) -> NSView.ToolTipTag {
        if let hint = owner as? ToolHint { hints.append(hint) }
        return super.addToolTip(rect, owner: owner, userData: data)
    }

    override func removeAllToolTips() {
        super.removeAllToolTips()
        hints.removeAll()
    }
}

final class ToolHint: NSObject, NSViewToolTipOwner {
    let tool: AnnotateTool
    init(tool: AnnotateTool) { self.tool = tool }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        "\(tool.title) (\(tool.key.uppercased())) – \(tool.hint)"
    }
}

extension AnnotateTool {
    /// What the tool does (the toolbar's hover hint).
    var hint: String {
        switch self {
        case .select: "Select, move and resize objects"
        case .rectangle: "Draw a rectangle outline"
        case .filledRectangle: "Draw a solid rectangle"
        case .ellipse: "Draw an ellipse"
        case .line: "Draw a straight line"
        case .arrow: "Draw an arrow"
        case .text: "Click to add text"
        case .redact: "Pixelate sensitive information"
        case .spotlight: "Dim everything except the selected area"
        case .counter: "Click to add numbered steps"
        case .emoji: "Click to place an emoji"
        case .draw: "Draw freehand"
        case .highlighter: "Highlight with a translucent marker"
        }
    }

    /// The modifier keys while using it (the sidebar, under the tool's name).
    var modifierHint: String {
        switch self {
        case .select: "Hold Shift to move straight or keep proportions, Option to drag a copy. Arrow keys nudge (Shift: 10 pt)."
        case .rectangle, .filledRectangle, .redact: "Hold Shift for a square, Option to draw from the center."
        case .spotlight: "Hold Shift for a square or circle, Option to draw from the center."
        case .ellipse: "Hold Shift for a circle, Option to draw from the center."
        case .line: "Hold Shift to snap to 45°, Option to draw from the center."
        case .arrow: "Hold Shift to snap to 45°, Option to flip its direction."
        case .text: "Press ⌘Return or Esc to finish. Double-click a text to edit it."
        case .counter: "Hold Shift to line it up with the last counter."
        case .emoji: "Hold Shift to line it up with the last emoji."
        case .draw: "Hold Shift for a straight line."
        case .highlighter: "Hold Shift for a straight line, Option to ignore lines of text."
        }
    }
}
