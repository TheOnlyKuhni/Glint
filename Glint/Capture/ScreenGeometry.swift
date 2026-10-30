import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    /// Frame in global CoreGraphics coordinates (origin at the top-left of the primary display, y down).
    var cgFrame: CGRect { Geometry.cgRect(fromAppKit: frame) }

    static var withMouse: NSScreen? {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main
    }

    static func containing(cgRect rect: CGRect) -> NSScreen? {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first { $0.cgFrame.contains(center) }
            ?? screens.max { $0.cgFrame.intersection(rect).area < $1.cgFrame.intersection(rect).area }
    }
}

enum Geometry {
    /// Height of the primary display, the pivot between AppKit (y up) and CoreGraphics (y down) coordinates.
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cgRect(fromAppKit r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func appKitRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgPoint(fromAppKit p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    /// Rect spanning two points, regardless of drag direction.
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var storageString: String { NSStringFromRect(self) }
    init?(storageString s: String) {
        guard !s.isEmpty else { return nil }
        self = NSRectFromString(s)
        if isEmpty { return nil }
    }
}
