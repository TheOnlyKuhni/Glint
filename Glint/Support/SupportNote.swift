import AppKit
import SwiftUI

/// A one-time thank-you note after the 50th capture, with a link to Ko-fi. It shows once, a moment after the capture,
/// in the bottom corner across from Quick Access, and closes with its ✕, a click on Support Glint, or by itself after
/// half a minute (unless the pointer is on it).
enum SupportNote {
    static let threshold = 50
    static let url = URL(string: "https://ko-fi.com/kuhni")!
    private static var panel: NSPanel?
    private static var hideTimer: Timer?

    /// Counts a finished capture; the 50th shows the note. Counting stops once it has been shown.
    static func captureDelivered() {
        guard !Defaults[Prefs.supportNoteShown] else { return }
        let count = Defaults[Prefs.captureCount] + 1
        Defaults[Prefs.captureCount] = count
        guard count >= threshold else { return }
        Defaults[Prefs.supportNoteShown] = true
        // Let the capture's own Quick Access card and sounds come first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { show() }
    }

    static func show() {
        hide(animated: false)
        guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let host = NSHostingView(rootView: SupportNoteView(
            support: { NSWorkspace.shared.open(url); hide() },
            close: { hide() }))
        let size = host.fittingSize
        let margin: CGFloat = 20, visible = screen.visibleFrame
        // Quick Access stacks its cards in one bottom corner; the note takes the other.
        let x = Defaults[Prefs.quickAccessPosition] == .left ? visible.maxX - size.width - margin : visible.minX + margin
        let panel = NSPanel(contentRect: CGRect(x: x, y: visible.minY + margin, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        self.panel = panel
        scheduleHide(after: 30)
    }

    /// Hides after `delay`, or later while the pointer rests on the note.
    private static func scheduleHide(after delay: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            guard let panel else { return }
            if panel.frame.contains(NSEvent.mouseLocation) { scheduleHide(after: 5) } else { hide() }
        }
    }

    static func hide(animated: Bool = true) {
        hideTimer?.invalidate()
        hideTimer = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }
}

private struct SupportNoteView: View {
    let support: () -> Void
    let close: () -> Void
    @State private var hoveringClose = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("That's 50 captures with Glint").font(.system(size: 13, weight: .semibold))
                Text("Glint is free and open source. If it's useful to you, a small tip on Ko-fi helps keep it going.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: support) { Label("Support Glint", systemImage: "heart") }
                    .controlSize(.small)
                    .padding(.top, 6)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(hoveringClose ? 0.1 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringClose = $0 }
            .help("Close")
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
