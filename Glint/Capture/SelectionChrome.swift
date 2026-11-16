import AppKit
import SwiftUI

// What every capture overlay shares while an area is being picked (the screenshot overlay, and the one for
// recording, scrolling capture and All-In-One): the hint pill in the middle until a drag starts, Glint's crosshair
// cursor, the coordinate pill beside it, a thin white border around the area, the guide lines across the screen
// (Settings: always or while holding ⌘), and scrolling that reaches the window underneath.

/// The guide lines through the pointer.
enum SelectionGuides {
    /// Whether they show: Settings → Screenshots → crosshair (always, while holding ⌘, or never).
    static func showsLines(commandHeld: Bool) -> Bool {
        switch Defaults[Prefs.crosshairMode] {
        case .disabled: false
        case .always: true
        case .holdingShift: commandHeld
        }
    }

    /// A horizontal and a vertical line through `p` across `bounds` (flipped view coordinates), on pixel centers.
    static func linesPath(through p: CGPoint, in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let x = p.x.rounded(.down) + 0.5, y = p.y.rounded(.down) + 0.5
        path.move(to: CGPoint(x: bounds.minX, y: y)); path.addLine(to: CGPoint(x: bounds.maxX, y: y))
        path.move(to: CGPoint(x: x, y: bounds.minY)); path.addLine(to: CGPoint(x: x, y: bounds.maxY))
        return path
    }

    /// The strips the lines through `p` cover (to redraw only those when the pointer moves).
    static func lineStrips(through p: CGPoint, in bounds: CGRect) -> [CGRect] {
        [CGRect(x: bounds.minX, y: p.y.rounded(.down) - 2, width: bounds.width, height: 5),
         CGRect(x: p.x.rounded(.down) - 2, y: bounds.minY, width: 5, height: bounds.height)]
    }

    /// Draws the lines like the screenshot overlay's: white at 75% with a faint dark edge.
    static func drawLines(through p: CGPoint, in bounds: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 1, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(linesPath(through: p, in: bounds))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The thin white border around a selected area (both overlays).
    static let borderColor = NSColor.white.withAlphaComponent(0.9)

    /// Puts `view` beside the pointer, flipping to the other side near the screen's edges.
    static func place(_ view: NSView, near mouse: CGPoint, offset: CGPoint, in bounds: CGRect) {
        let size = view.fittingSize
        var origin = CGPoint(x: mouse.x + offset.x, y: mouse.y + offset.y)
        if origin.x + size.width > bounds.width - 4 { origin.x = mouse.x - offset.x - size.width }
        if origin.y + size.height > bounds.height - 4 { origin.y = mouse.y - offset.y - size.height }
        view.frame = CGRect(origin: origin, size: size)
    }
}

/// The light hint pill in the middle of an overlay ("Drag to …"), for flipped superviews. It fades to 10% in 0.1 s
/// while the pointer is near it (the pill plus ~52pt around it, ~65pt above), and never takes clicks.
final class CaptureHintView: NSView {
    private let host: NSHostingView<ScreenHintPill>
    private var faded = false

    var text: String {
        didSet { if text != oldValue { host.rootView = ScreenHintPill(text: text); recenter() } }
    }

    init(text: String) {
        self.text = text
        host = NSHostingView(rootView: ScreenHintPill(text: text))
        host.sizingOptions = [.intrinsicContentSize]
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        recenter()
    }

    /// Centered in the superview.
    func recenter() {
        guard let superview else { return }
        let size = host.fittingSize
        frame = CGRect(x: (superview.bounds.width - size.width) / 2, y: (superview.bounds.height - size.height) / 2,
                       width: size.width, height: size.height)
        host.frame = bounds
    }

    func setShown(_ shown: Bool) {
        guard isHidden == shown else { return }
        isHidden = !shown
        if !shown { faded = false; alphaValue = 1 }
    }

    /// The pointer in the superview's (flipped) coordinates.
    func pointerMoved(to p: CGPoint) {
        let zone = frame.insetBy(dx: -52, dy: -57).offsetBy(dx: 2, dy: -8)
        let near = !isHidden && zone.contains(p)
        guard near != faded else { return }
        faded = near
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            animator().alphaValue = near ? 0.1 : 1
        }
    }
}

/// Scrolling (trackpad or wheel, both directions) over an overlay reaches the window underneath, so the content
/// can still be moved into place while an area is picked. Needs the permission to control the computer
/// (Accessibility, which Auto-Scroll asks for); without it scrolling just does nothing, as before.
enum ScrollPassThrough {
    private static var windows: [WindowInfo] = []
    private static var windowsRead = Date.distantPast

    static func forward(_ event: NSEvent) {
        guard CGPreflightPostEventAccess(), let cg = event.cgEvent?.copy() else { return }
        // Read again at most twice a second (scroll events come at up to 120 a second).
        if Date().timeIntervalSince(windowsRead) > 0.5 {
            windows = WindowInfo.onScreen()
            windowsRead = Date()
        }
        let p = cg.location
        guard let target = windows.first(where: { $0.frame.contains(p) }), target.pid > 0 else { return }
        // The window the app routes it to (as if the pointer were over it with nothing in between).
        for field in [91, 92] {  // kCGMouseEventWindowUnderMousePointer(ThatCanHandleThisEvent)
            if let f = CGEventField(rawValue: UInt32(field)) { cg.setIntegerValueField(f, value: Int64(target.id)) }
        }
        cg.postToPid(target.pid)
    }
}
