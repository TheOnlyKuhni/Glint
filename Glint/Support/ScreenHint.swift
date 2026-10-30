import AppKit
import SwiftUI

/// The light hint pill in the middle of the screen (like the recorder's), as its own click-through panel. It fades to
/// 10% in 0.1 s while the pointer is in its hover zone (the pill plus ~52pt around it, ~65pt above). Used while dragging a file out of the editor.
enum ScreenHint {
    private static var panel: NSPanel?
    private static var faded = false

    static func show(_ text: String, on screen: NSScreen? = NSScreen.withMouse ?? NSScreen.main) {
        hide()
        guard let screen else { return }
        let host = NSHostingView(rootView: ScreenHintPill(text: text))
        let size = host.fittingSize
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        self.panel = panel
        faded = false
        pointerMoved(to: NSEvent.mouseLocation)
    }

    /// Global (AppKit) pointer position.
    static func pointerMoved(to p: NSPoint) {
        guard let panel else { return }
        let zone = panel.frame.insetBy(dx: -52, dy: -57).offsetBy(dx: 2, dy: 8)
        let near = zone.contains(p)
        guard near != faded else { return }
        faded = near
        NSAnimationContext.runAnimationGroup { $0.duration = 0.1; panel.animator().alphaValue = near ? 0.1 : 1 }
    }

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ScreenHintPill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Color(white: 0.12))
            .padding(.horizontal, 28)
            .frame(height: 60)
            .background(Capsule().fill(Color(white: 0.84).opacity(0.97)))
            .fixedSize()
    }
}
