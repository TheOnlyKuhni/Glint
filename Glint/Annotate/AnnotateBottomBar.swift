import AppKit
import SwiftUI

@Observable
final class AnnotateBottomBarModel {
    var zoom: CGFloat = 1
    var growsCanvas = Defaults[Prefs.annotateExpandCanvas]
    var locksCanvas = Defaults[Prefs.annotateLockCanvas]
}

/// Zoom menu, Grow and Lock Canvas, "Drag Me" handle and the Pin / Copy buttons along the bottom of the editor.
struct AnnotateBottomBar: View {
    struct Actions {
        var zoomIn: () -> Void
        var zoomOut: () -> Void
        var actualSize: () -> Void
        var zoomToFit: () -> Void
        var setZoom: (CGFloat) -> Void
        var toggleGrowCanvas: () -> Void
        var toggleLockCanvas: () -> Void
        var pin: () -> Void
        var copy: () -> Void
        var dragFile: () -> URL?
        var prepareDrag: () -> Void
        /// The dragged image was dropped somewhere: editing is over.
        var dropped: () -> Void
    }

    let model: AnnotateBottomBarModel
    let actions: Actions

    var body: some View {
        ZStack {
            HStack {
                Menu {
                    Button("Zoom In", action: actions.zoomIn).keyboardShortcut("+", modifiers: .command)
                    Button("Zoom Out", action: actions.zoomOut).keyboardShortcut("-", modifiers: .command)
                    Divider()
                    Button("Actual Size", action: actions.actualSize).keyboardShortcut("0", modifiers: .command)
                    Button("Zoom to Fit", action: actions.zoomToFit).keyboardShortcut("9", modifiers: .command)
                    Divider()
                    ForEach([2.0, 1.0, 0.75, 0.5, 0.25, 0.1], id: \.self) { level in
                        Button("\(Int(level * 100))%") { actions.setZoom(level) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit()
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(BarButtonStyle())
                .fixedSize()

                // Canvas-wide, so it sits with the zoom rather than with the tool options.
                Button(action: actions.toggleGrowCanvas) {
                    Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 22)
                }
                .buttonStyle(BarButtonStyle(isOn: model.growsCanvas))
                .help(model.growsCanvas ? "Grow Canvas is on: annotations past the edge widen the canvas on every side, so the screenshot stays centered. Click to cut them off at the screenshot's edge instead."
                                         : "Grow Canvas is off: annotations are cut off at the screenshot's edge. Click to widen the canvas to fit them.")

                Button(action: actions.toggleLockCanvas) {
                    Image(systemName: model.locksCanvas ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 22)
                }
                .buttonStyle(BarButtonStyle(isOn: model.locksCanvas))
                .help(model.locksCanvas ? "Lock Canvas is on: drawing over an object draws, it never picks the object up (use Select to move objects). Click to unlock."
                                        : "Lock Canvas is off: starting a drawing on an object selects and moves it instead. Click to lock.")

                Spacer()

                HStack(spacing: 8) {
                    BarIconButton(symbol: "pin.fill", help: "Pin to the screen", action: actions.pin)
                    BarIconButton(symbol: "doc.on.doc.fill", help: "Copy to clipboard (⇧⌘C)", action: actions.copy)
                }
            }
            DragMeHandle(fileProvider: actions.dragFile, prepare: actions.prepareDrag, dropped: actions.dropped)
                .frame(width: 150, height: 32)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The editors' dark bar with a hairline above.
        .background(Color(white: 0x21 / 255.0))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(white: 0x30 / 255.0)).frame(height: 1)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct BarButtonStyle: ButtonStyle {
    /// A toggle that's on: blue, like an active mode button.
    var isOn = false
    func makeBody(configuration: Configuration) -> some View { BarButtonBody(configuration: configuration, isOn: isOn) }
}

/// Hover brightens slightly; press brightens more and shrinks, starting from the hovered state.
private struct BarButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var isOn = false
    @State private var hovering = false
    private static let blue = Color(.displayP3, red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Capsule().fill(isOn ? Self.blue : Color(white: configuration.isPressed ? 0.26 : (hovering ? 0.21 : 0x2A / 255.0))))
            .overlay(Capsule().fill(Color.black.opacity(isOn && configuration.isPressed ? 0.24 : (isOn && hovering ? 0.1 : 0))))
            .animation(.easeOut(duration: 0.12), value: isOn)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

private struct BarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 22)
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
    }
}

/// "≡ Drag Me ≡" pill: drag it out to drop the annotated image into any app.
private struct DragMeHandle: NSViewRepresentable {
    let fileProvider: () -> URL?
    let prepare: () -> Void
    let dropped: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.fileProvider = fileProvider
        view.prepare = prepare
        view.dropped = dropped
        return view
    }

    func updateNSView(_ view: DragView, context: Context) { view.fileProvider = fileProvider }

    final class DragView: NSView, NSDraggingSource {
        var fileProvider: (() -> URL?)?
        var prepare: (() -> Void)?
        var dropped: (() -> Void)?
        private var downEvent: NSEvent?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { prepare?() }

        override func draw(_ dirtyRect: NSRect) {
            let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            NSColor.white.withAlphaComponent(0.07).setFill()
            pill.fill()
            NSColor.white.withAlphaComponent(0.14).setStroke()
            pill.stroke()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor]
            let text = "Drag Me" as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
            if let grip = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) {
                let tinted = grip.tinted(.tertiaryLabelColor)
                let g = tinted.size
                tinted.draw(in: NSRect(x: bounds.midX - size.width / 2 - g.width - 12, y: bounds.midY - g.height / 2, width: g.width, height: g.height))
                tinted.draw(in: NSRect(x: bounds.midX + size.width / 2 + 12, y: bounds.midY - g.height / 2, width: g.width, height: g.height))
            }
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard downEvent != nil, let url = fileProvider?() else { return }
            downEvent = nil
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSImage(contentsOf: url))
            beginDraggingSession(with: [item], event: event, source: self)
            ScreenHint.show("Drag the file to drop it. Press Esc to cancel.")
            // The editor gets out of the way so the image can be dropped into the window behind it.
            if let window {
                window.ignoresMouseEvents = true
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 0 }
            }
        }

        /// Dropped somewhere: the editor closes (the usual flow is edit, then put the file away). Cancelled: it comes back.
        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            ScreenHint.pointerMoved(to: screenPoint)
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ScreenHint.hide()
            guard let window else { return }
            window.ignoresMouseEvents = false
            if !operation.isEmpty, let dropped {
                dropped()
                return
            }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; window.animator().alphaValue = 1 }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .generic]
        }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
