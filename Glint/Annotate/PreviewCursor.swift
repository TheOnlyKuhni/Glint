import AppKit

/// Outline cursors that preview the size of the pen / highlighter.
enum PreviewCursor {
    private static var cache: [String: NSCursor] = [:]

    /// Vertical capsule (marker tip): height = band height on screen.
    static func marker(height: CGFloat) -> NSCursor {
        let h = min(max(height, 8), 120).rounded()
        let w = max(6, (h * 0.66).rounded())
        return cursor(key: "m\(Int(h))", size: CGSize(width: w + 4, height: h + 4)) { rect in
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: w / 2, yRadius: w / 2)
        }
    }

    /// Circle: diameter = stroke width on screen.
    static func circle(diameter: CGFloat) -> NSCursor {
        let d = min(max(diameter, 6), 120).rounded()
        return cursor(key: "c\(Int(d))", size: CGSize(width: d + 4, height: d + 4)) { rect in
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        }
    }

    /// Double outline (white inside a dark ring) so it reads on any background.
    private static func cursor(key: String, size: CGSize, shape: @escaping (NSRect) -> NSBezierPath) -> NSCursor {
        if let cached = cache[key] { return cached }
        let image = NSImage(size: size, flipped: false) { rect in
            let path = shape(rect)
            NSColor.black.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 3
            path.stroke()
            NSColor.white.setStroke()
            path.lineWidth = 1.2
            path.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
        cache[key] = cursor
        return cursor
    }
}
