import AppKit
import SwiftUI

/// What an option button shows in front of its chevron.
enum OptionLabel {
    /// Template image, tinted like the other toolbar glyphs.
    case glyph(NSImage)
    /// Image drawn as is (the color swatch).
    case image(NSImage)
    case text(String)
}

final class OptionButtonModel: ObservableObject {
    @Published var label: OptionLabel = .text("")
    @Published var isOpen = false
}

/// A per-tool option in the Annotate toolbar: a 26pt gray capsule with the current value and a
/// chevron. Mouse-down opens `menu`: the color menu drops below the button, every other menu opens over it with
/// its first item on the button. Without a menu, `onClick` runs instead (the lock).
final class OptionControl {
    let model = OptionButtonModel()
    let view: NSView
    var menu: NSMenu?
    var dropsDown = false
    var onClick: (() -> Void)?
    private let host: OptionHostingView

    init(chevron: Bool = true) {
        host = OptionHostingView(rootView: OptionButton(model: model, chevron: chevron))
        host.sizingOptions = [.intrinsicContentSize]
        view = host
        host.onMouseDown = { [weak self] in self?.open() }
    }

    var value: OptionLabel {
        get { model.label }
        set { model.label = newValue }
    }

    var toolTip: String? {
        get { host.toolTip }
        set { host.toolTip = newValue }
    }

    private func open() {
        guard let menu else { onClick?(); return }
        model.isOpen = true
        let width = menu.size.width
        let x = host.bounds.midX - width / 2
        if dropsDown {
            // Top of the menu at the bottom edge of the toolbar, 12.5pt below the button.
            let y = host.isFlipped ? host.bounds.maxY + 12.5 : host.bounds.minY - 12.5
            menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: host)
        } else {
            menu.popUp(positioning: menu.items.first, at: NSPoint(x: x, y: host.isFlipped ? host.bounds.minY : host.bounds.maxY), in: host)
        }
        model.isOpen = false
    }
}

final class OptionHostingView: NSHostingView<OptionButton> {
    var onMouseDown: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onMouseDown?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct OptionButton: View {
    @ObservedObject var model: OptionButtonModel
    let chevron: Bool
    @State private var hovering = false

    static let glyphColor = Color(.displayP3, red: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xE5 / 255.0)

    var body: some View {
        content
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(model.isOpen ? 0.4 : 0.2)))
            .overlay(Capsule().fill(Color.black.opacity(hovering && !model.isOpen ? 0.1 : 0)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }

    /// Fixed-width buttons center their value 15pt from the left and the chevron at 31.5pt;
    /// text buttons grow with the text.
    @ViewBuilder private var content: some View {
        switch model.label {
        case .text(let text):
            // Whole-point width keeps the following buttons on the pixel grid.
            let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
            HStack(spacing: 3) {
                Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(Self.glyphColor).fixedSize()
                OptionChevron()
            }
            .padding(.leading, 7.5)
            .frame(width: (7.5 + width + 3 + 8 + 4.5).rounded(), alignment: .leading)
        case .glyph(let image):
            fixed(Image(nsImage: image).foregroundStyle(Self.glyphColor))
        case .image(let image):
            fixed(Image(nsImage: image))
        }
    }

    private func fixed(_ value: some View) -> some View {
        ZStack {
            value.position(x: chevron ? 15 : 18, y: 13)
            if chevron { OptionChevron().position(x: 31.5, y: 13) }
        }
        .frame(width: chevron ? 40 : 36, height: 26)
    }
}

/// The small down chevron: 6.6×3.6pt, 1.4pt round stroke at 27% white.
struct OptionChevron: View {
    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 0.7, y: 0.7))
            p.addLine(to: CGPoint(x: 4, y: 4.3))
            p.addLine(to: CGPoint(x: 7.3, y: 0.7))
        }
        .stroke(Color.white.opacity(0.27), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        .frame(width: 8, height: 5)
    }
}

/// Values shown on option buttons and in their menus.
enum OptionGlyph {
    /// Color dot with a 1pt white ring.
    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 15, height: 15), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect).fill()
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Diagonal stroke whose width follows the thickness step.
    static func thickness(_ width: CGFloat) -> NSImage {
        template(CGSize(width: 12, height: 12)) { ctx in
            ctx.setLineWidth(0.6 + width * 0.19)
            ctx.setLineCap(.round)
            ctx.move(to: CGPoint(x: 1.5, y: 10.5))
            ctx.addLine(to: CGPoint(x: 10.5, y: 1.5))
            ctx.strokePath()
        }
    }

    /// The tool glyph, drawn `scale` times larger.
    static func scaled(_ tool: AnnotateTool, _ scale: CGFloat) -> NSImage {
        let base = ToolGlyph.image(for: tool)
        let size = CGSize(width: base.size.width * scale, height: base.size.height * scale)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Small arrow for the style button, pointing to the bottom left like the tool glyph.
    static func arrowStyle(_ style: ArrowStyle) -> NSImage {
        if style == .standard { return scaled(.arrow, 1.2) }
        return template(CGSize(width: 16, height: 16)) { ctx in
            let tip = CGPoint(x: 2.5, y: 13.5), tail = CGPoint(x: 13.5, y: 2.5)
            switch style {
            case .fancy:
                // Tapered shaft into a swept-back head.
                ctx.move(to: tail)
                ctx.addLine(to: CGPoint(x: 7.2, y: 10.2))
                ctx.addLine(to: CGPoint(x: 8.6, y: 13.4))
                ctx.addLine(to: tip)
                ctx.addLine(to: CGPoint(x: 2.6, y: 7.4))
                ctx.addLine(to: CGPoint(x: 5.8, y: 8.8))
                ctx.closePath()
                ctx.fillPath()
            case .curved, .double:
                let control = CGPoint(x: 2.5, y: 2.5)
                ctx.setLineWidth(1.8)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: tail)
                ctx.addQuadCurve(to: tip, control: control)
                ctx.strokePath()
                head(ctx, tip: tip, from: control)
                if style == .double { head(ctx, tip: tail, from: control) }
            case .standard:
                break
            }
        }
    }

    /// Wide, left-pointing preview of an arrow style for its menu.
    static func arrowPreview(_ style: ArrowStyle) -> NSImage {
        template(CGSize(width: 44, height: 22)) { ctx in
            var a = Annotation(kind: .arrow, start: CGPoint(x: 41, y: 11), end: CGPoint(x: 3, y: 11), color: .red, thickness: 0)
            a.variant = style.rawValue
            if a.isBendable {
                a.start.y = 17; a.end.y = 17
                a.control = CGPoint(x: 22, y: 7)
            }
            AnnotationRenderer.drawArrow(a, style: style, color: .black, width: 2.6, ctx: ctx)
        }
    }

    private static func head(_ ctx: CGContext, tip: CGPoint, from: CGPoint) {
        let dx = tip.x - from.x, dy = tip.y - from.y, len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len
        let back = CGPoint(x: tip.x - ux * 5, y: tip.y - uy * 5)
        ctx.move(to: tip)
        ctx.addLine(to: CGPoint(x: back.x - uy * 3.2, y: back.y + ux * 3.2))
        ctx.addLine(to: CGPoint(x: back.x + uy * 3.2, y: back.y - ux * 3.2))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Outline of a spotlight shape.
    static func spotlight(_ shape: SpotlightShape) -> NSImage {
        template(CGSize(width: 16, height: 13)) { ctx in
            let r = CGRect(x: 1, y: 1, width: 14, height: 11)
            ctx.setLineWidth(2)
            switch shape {
            case .rectangle: ctx.addPath(CGPath(roundedRect: r, cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
            case .rounded: ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
            case .ellipse: ctx.addEllipse(in: r)
            }
            ctx.strokePath()
        }
    }

    /// Redact mode icon: the pixel checker, a drop (with a lock for secure blur) or a crescent.
    static func redact(_ mode: RedactMode) -> NSImage {
        switch mode {
        case .pixelate: return ToolGlyph.image(for: .redact)
        case .blurSmooth: return symbol("drop.fill", 13)
        case .blackOut: return symbol("moon.fill", 13)
        case .blurSecure:
            return template(CGSize(width: 16, height: 16)) { ctx in
                guard let drop = symbolImage("drop.fill", 13), let lock = symbolImage("lock.fill", 7.5) else { return }
                drop.draw(in: CGRect(x: 1, y: 1, width: drop.size.width, height: drop.size.height))
                let badge = CGRect(x: 16 - lock.size.width, y: 16 - lock.size.height, width: lock.size.width, height: lock.size.height)
                ctx.setBlendMode(.clear)
                ctx.fill(badge.insetBy(dx: -1, dy: -1))
                ctx.setBlendMode(.normal)
                lock.draw(in: badge)
            }
        }
    }

    /// The counter style button.
    static let counterStyle: NSImage = symbol("textformat.123", 13)

    /// The text style button.
    static let textStyle: NSImage = symbol("textformat", 13)

    static func symbol(_ name: String, _ size: CGFloat) -> NSImage {
        let image = symbolImage(name, size) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private static func symbolImage(_ name: String, _ size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .medium))
    }

    /// Template image drawn y-down.
    static func template(_ size: CGSize, _ draw: @escaping (CGContext) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            draw(ctx)
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The "Save as..." button: a 26pt capsule with 13pt medium text; gray, or blue when prominent.
/// Hover darkens; press darkens more and shrinks.
struct BarTextButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View { BarTextButtonBody(configuration: configuration, prominent: prominent) }
}

private struct BarTextButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 8.75)
            .frame(height: 26)
            .background(Capsule().fill(prominent ? Color(.displayP3, red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)
                                                 : Color.white.opacity(0.2)))
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.24 : (hovering ? 0.1 : 0))))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

/// The redact strength / spotlight dimming slider: a 100×4pt track filled blue up to an
/// 18×14pt capsule knob, with a small dot under the knob.
final class AmountSliderModel: ObservableObject {
    @Published var value: CGFloat = 0.5
    var onChange: ((CGFloat) -> Void)?
}

struct AmountSlider: View {
    @ObservedObject var model: AmountSliderModel
    @Environment(\.controlActiveState) private var windowState

    /// The knob's center follows the value across the whole track, so it overhangs both ends by up to 9pt.
    private static let track: CGFloat = 100, inset: CGFloat = 5

    var body: some View {
        let x = Self.inset + model.value * Self.track
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.white.opacity(0.1))
                .frame(width: Self.track, height: 4).offset(x: Self.inset, y: 11)
            Capsule().fill(windowState == .inactive ? Color.white.opacity(0.35)
                                                    : Color(.displayP3, red: 0x39 / 255.0, green: 0x7B / 255.0, blue: 0xF6 / 255.0))
                .frame(width: max(x - Self.inset, 4), height: 4).offset(x: Self.inset, y: 11)
            Circle().fill(Color.white.opacity(0.15))
                .frame(width: 3, height: 3).offset(x: x - 1.5, y: 21.75)
            Capsule().fill(Color(.displayP3, red: 0xE2 / 255.0, green: 0xE2 / 255.0, blue: 0xE2 / 255.0))
                .frame(width: 18, height: 14)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .offset(x: x - 9, y: 6)
        }
        .frame(width: Self.track + Self.inset + 9, height: 26, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let v = min(max((g.location.x - Self.inset) / Self.track, 0), 1)
            model.value = v
            model.onChange?(v)
        })
    }
}
