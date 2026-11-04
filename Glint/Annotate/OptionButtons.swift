import AppKit
import SwiftUI

/// Glyphs for the Annotate sidebar's style choices (template images).
enum OptionGlyph {
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

/// The head bars' buttons (Save as…, Done, Save, Export, Share): the bottom bar's capsules, blue when prominent.
struct BarTextButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View { BarButtonBody(configuration: configuration, isOn: prominent, horizontalPadding: 14) }
}
