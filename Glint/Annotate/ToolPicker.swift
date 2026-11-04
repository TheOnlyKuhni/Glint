import AppKit
import SwiftUI

/// The Annotate toolbar: one near-black dock (the canvas's black, with the bottom bar's hairline) holding the tools in
/// four groups: select, shapes, marks, drawing. A blue pill slides to the selected tool (gray while the window is
/// inactive); hovering lights a tool up on the buttons' gray. While cropping the tools rest: none is selected and they're
/// dimmed and off until Crop & Resize ends.
struct ToolPicker: View {
    let doc: AnnotationDocument
    let onSelect: (AnnotateTool) -> Void
    @State private var hovered: AnnotateTool?
    @Namespace private var pill
    @Environment(\.controlActiveState) private var windowState

    static let cellWidth: CGFloat = 33
    static let inset: CGFloat = 3
    private static let groupGap: CGFloat = 11
    /// The tool that starts each group after the first.
    private static let groupStarts: Set<AnnotateTool> = [.rectangle, .text, .draw]
    private static let dock = Color(white: 0x17 / 255.0)
    private static let hoverFill = Color(white: 0x2A / 255.0)
    private static let selectedFill = Color(.displayP3, red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)

    /// A tool's left edge inside the picker (the tooltips use it too).
    static func offset(of tool: AnnotateTool) -> CGFloat {
        let index = AnnotateTool.allCases.firstIndex(of: tool) ?? 0
        let gaps = AnnotateTool.allCases.prefix(index + 1).filter(groupStarts.contains).count
        return inset + CGFloat(index) * cellWidth + CGFloat(gaps) * groupGap
    }

    var body: some View {
        let inactive = windowState == .inactive
        let resting = doc.isCropping || doc.toolsResting
        HStack(spacing: 0) {
            ForEach(AnnotateTool.allCases) { tool in
                if Self.groupStarts.contains(tool) {
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 16).frame(width: Self.groupGap)
                }
                cell(tool, selected: !resting && tool == doc.tool, inactive: inactive, resting: resting)
            }
        }
        .padding(Self.inset)
        .background(Capsule().fill(Self.dock))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .opacity(resting ? 0.4 : 1)
        .allowsHitTesting(!resting)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: doc.tool)
        .animation(.easeOut(duration: 0.15), value: resting)
    }

    private func cell(_ tool: AnnotateTool, selected: Bool, inactive: Bool, resting: Bool) -> some View {
        Button { onSelect(tool) } label: {
            Image(nsImage: ToolGlyph.image(for: tool))
                .foregroundStyle(selected || hovered == tool ? Color.white : Color(white: inactive ? 0.45 : 0.62))
                .frame(width: Self.cellWidth, height: 26)
                .background {
                    if selected {
                        Capsule().fill(inactive ? Color.white.opacity(0.2) : Self.selectedFill).matchedGeometryEffect(id: "selected", in: pill)
                    } else if hovered == tool {
                        Capsule().fill(Self.hoverFill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(ToolCellStyle())
        .onHover { hovered = $0 && !resting ? tool : (hovered == tool ? nil : hovered) }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// A press pushes the tool in.
private struct ToolCellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
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
        for tool in AnnotateTool.allCases {
            addToolTip(CGRect(x: ToolPicker.offset(of: tool), y: 0, width: ToolPicker.cellWidth, height: bounds.height), owner: ToolHint(tool: tool), userData: nil)
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
