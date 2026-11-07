import AppKit
import SwiftUI

/// The thumbnail card shown in the Quick Access overlay.
struct QuickAccessCard: View {
    struct Actions {
        var copy: () -> Void
        var save: () -> Void
        var close: () -> Void
        var annotate: () -> Void
        var pin: () -> Void
        var share: () -> Void
        var hoverChanged: (Bool) -> Void
    }

    let item: CaptureItem
    let actions: Actions
    let hover: HoverState
    private var isHovering: Bool { hover.isHovering }
    private var isEditing: Bool { hover.isEditing }
    /// Lightens dark captures but darkens bright ones so the light buttons stay readable.
    private let hoverScrim: Color

    init(item: CaptureItem, actions: Actions, hover: HoverState) {
        self.item = item
        self.actions = actions
        self.hover = hover
        hoverScrim = item.averageLuminance > 0.6 ? Color.black.opacity(0.35) : Color.white.opacity(0.19)
    }

    private let corner: CGFloat = 16
    private let background = Color(white: 0.105)

    var body: some View {
        ZStack {
            background
            // Color.clear sets the size; the filled image overflows it and gets clipped.
            Color.clear
                .overlay(Image(nsImage: item.nsImage).resizable().interpolation(.high).aspectRatio(contentMode: .fill))
                .clipped()
                .blur(radius: isHovering ? 14 : 0, opaque: false)

            if item.isRecording, !isHovering { RecordingFooter(item: item) }

            if isHovering, isEditing {
                // Open in an editor: no buttons, a click anywhere brings the editor forward.
                Rectangle().fill(hoverScrim)
                Text("Being edited…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 11)
                    .frame(height: 27)
                    .background(Capsule().fill(buttonFill))
            } else if isHovering {
                Rectangle().fill(hoverScrim)

                VStack(spacing: 10) {
                    PillButton(title: "Copy", action: actions.copy).delayedHint("Copy to clipboard")
                    PillButton(title: "Save", action: actions.save).delayedHint("Save to your export location", above: false)
                }

                VStack {
                    HStack {
                        CornerButton(symbol: "xmark", help: "Close", action: actions.close)
                        Spacer()
                        if item.isRecording {
                            CornerButton(symbol: "eye", help: "Preview", action: actions.pin)
                        } else {
                            CornerButton(symbol: "pin.fill", help: "Pin to the screen", rotation: 45, action: actions.pin)
                        }
                    }
                    Spacer()
                    HStack {
                        CornerButton(symbol: item.isRecording ? "scissors" : "pencil", help: item.isRecording ? "Edit video" : "Annotate",
                                     hintAbove: true, action: actions.annotate)
                        Spacer()
                        CornerButton(symbol: "square.and.arrow.up", help: "Share", hintAbove: true, action: actions.share)
                    }
                }
                .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(quickAccessBorder, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .opacity(isEditing && !isHovering ? 0.45 : 1)
        .animation(.easeOut(duration: 0.2), value: hover.isEditing)
    }
}

/// Bottom bar of a recording card: video (or GIF) icon and duration, file size on the right.
struct RecordingFooter: View {
    let item: CaptureItem

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                if item.isGIF {
                    Text("GIF").font(.system(size: 8, weight: .black)).foregroundStyle(Color(white: 0.12))
                        .frame(width: 20, height: 13).background(RoundedRectangle(cornerRadius: 3).fill(.white))
                } else {
                    Image(systemName: "video.fill").font(.system(size: 13))
                }
                Text(Self.duration(item.duration ?? 0)).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Color(white: 0.28).opacity(0.55))  // translucent gray, not black
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Semi-transparent white, so it reads as #515151 on dark captures and light gray on bright ones.
let quickAccessBorder = Color.white.opacity(0.26)

/// Hover and press state of the restore tab and the hide bar, fed from their panel.
@Observable
final class BarState {
    var hovering = false
    var pressed = false
}

/// The dark fill of the restore tab and the hide bar: the editors' box color, a little lighter on hover.
private func barFill(_ state: BarState) -> Color {
    Color(white: state.pressed ? 0.27 : (state.hovering ? 0.22 : 0.165))
}

/// The tab that peeks up from the bottom edge while the overlays are swiped away. Hovering lifts the chevron.
struct QuickAccessRestoreTab: View {
    let state: BarState

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous)
        ZStack(alignment: .top) {
            shape.fill(barFill(state))
            BarChevron(pointsUp: true)
                .stroke(Color.white.opacity(state.hovering ? 1 : 0.85), style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
                .frame(width: 32, height: 6)
                .padding(.top, 11.5)
                .offset(y: state.hovering ? -2 : 0)
        }
        .overlay(shape.strokeBorder(quickAccessBorder, lineWidth: 1))
        .scaleEffect(state.pressed ? 0.97 : 1, anchor: .bottom)
        .animation(.easeOut(duration: 0.15), value: state.hovering)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: state.pressed)
        .contentShape(Rectangle())
    }
}

/// The bar above the top card that tucks the stack away: the restore tab's look, as a floating rounded bar with the
/// chevron pointing down. Hovering nudges the chevron down.
struct QuickAccessHideBar: View {
    let state: BarState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            shape.fill(barFill(state))
            BarChevron(pointsUp: false)
                .stroke(Color.white.opacity(state.hovering ? 1 : 0.85), style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
                .frame(width: 32, height: 6)
                .offset(y: state.hovering ? 2 : 0)
        }
        .overlay(shape.strokeBorder(quickAccessBorder, lineWidth: 1))
        .scaleEffect(state.pressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.15), value: state.hovering)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: state.pressed)
        .contentShape(shape)
    }
}

/// The soft chevron of both bars.
private struct BarChevron: Shape {
    let pointsUp: Bool

    func path(in r: CGRect) -> Path {
        let tip = pointsUp ? r.minY : r.maxY, ends = pointsUp ? r.maxY : r.minY
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: ends))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: tip), control: CGPoint(x: r.midX - r.width * 0.22, y: tip))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: ends), control: CGPoint(x: r.midX + r.width * 0.22, y: tip))
        return p
    }
}

/// Hover state fed from an AppKit tracking area, which (unlike SwiftUI's onHover) works while Glint is inactive.
@Observable
final class HoverState {
    var isHovering = false
    /// Open in an editor: the card is see-through and has no buttons (it can't be opened twice).
    var isEditing = false
}

/// Container that reports mouse enter/exit regardless of app activation.
final class HoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

private let buttonFill = Color(red: 0.843, green: 0.843, blue: 0.847)  // #D7D7D8

private struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 11)
                .frame(height: 27)
        }
        .buttonStyle(CardButtonStyle(shape: Capsule()))
    }
}

private struct CornerButton: View {
    let symbol: String
    let help: String
    var rotation: Double = 0
    var hintAbove = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                Image(systemName: symbol)
                    .font(.system(size: symbol == "pencil" ? 11 : 9.5, weight: .bold))
                    .rotationEffect(.degrees(rotation))
            }
            .foregroundStyle(.black.opacity(0.85))
            .frame(width: 22, height: 22)
        }
        .buttonStyle(CardButtonStyle(shape: Circle()))
        .delayedHint(help, above: hintAbove)
    }
}

/// Light button with two separate effects: hovering darkens it a little, pressing darkens it further
/// and shrinks it — the press starts from the hovered look.
struct CardButtonStyle<S: Shape>: ButtonStyle {
    let shape: S
    func makeBody(configuration: Configuration) -> some View { CardButtonBody(configuration: configuration, shape: shape) }
}

private struct CardButtonBody<S: Shape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: S
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(shape.fill(buttonFill))
            .overlay(shape.fill(Color.black.opacity(configuration.isPressed ? 0.24 : (hovering ? 0.1 : 0))).allowsHitTesting(false))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

extension CaptureItem {
    /// 0 (black) … 1 (white), sampled from a tiny downscale.
    var averageLuminance: CGFloat {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let p = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        return (0.299 * CGFloat(p[0]) + 0.587 * CGFloat(p[1]) + 0.114 * CGFloat(p[2])) / 255
    }
}

/// Tooltip that appears after ~1s of hovering, also in non-activating panels where native tooltips don't show.
struct DelayedHint: ViewModifier {
    let text: String
    var above = false
    @State private var visible = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                task?.cancel()
                if hovering {
                    task = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { visible = true } }
                    }
                } else {
                    visible = false
                }
            }
            .overlay(alignment: above ? .top : .bottom) {
                if visible {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.black.opacity(0.8)))
                        .offset(y: above ? -24 : 24)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
    }
}

extension View {
    func delayedHint(_ text: String, above: Bool = false) -> some View { modifier(DelayedHint(text: text, above: above)) }
}
