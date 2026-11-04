import AppKit
import SwiftUI

/// The editors' bar under the title bar: under the tabs too when several editors share a window as tabs (a toolbar
/// would sit above them). A dark 46pt strip with a hairline below. `center` (the screenshot editor's tools) stays
/// over the middle of the workspace right of `centerInset` and moves aside for `trailing` (the buttons on the right).
final class EditorHeadBar: NSView {
    static let height: CGFloat = 46

    init(center: NSView? = nil, centerInset: CGFloat = 0, trailing: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0x21 / 255.0, alpha: 1).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor(white: 0x30 / 255.0, alpha: 1).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailing)
        addSubview(hairline)
        var constraints = [
            heightAnchor.constraint(equalToConstant: Self.height),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
        ]
        if let center {
            center.translatesAutoresizingMaskIntoConstraints = false
            addSubview(center)
            // Over the workspace's middle while there's room; never under the buttons or left of the workspace.
            let middle = center.centerXAnchor.constraint(equalTo: centerXAnchor, constant: centerInset / 2)
            middle.priority = .defaultHigh
            constraints += [
                middle,
                center.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
                center.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -16),
                center.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: max(centerInset, 12)),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Clicks on the empty bar move the window, like a title bar.
    override var mouseDownCanMoveWindow: Bool { true }

    /// The window: title in a transparent title bar, no toolbar, content under the title bar (the head bar starts
    /// at the safe area, below the title bar and any tabs).
    static func configure(_ window: NSWindow) {
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
    }

    /// The band behind the title bar (and tabs), above the head bar.
    static func titleBand() -> NSView {
        let band = NSView()
        band.wantsLayer = true
        band.layer?.backgroundColor = NSColor(white: 0x21 / 255.0, alpha: 1).cgColor
        band.translatesAutoresizingMaskIntoConstraints = false
        return band
    }
}

/// Share in a head bar: the capsule of "Save as…" with the share symbol; reports itself as the anchor for the
/// sharing picker.
struct HeadShareButton: NSViewRepresentable {
    let help: String
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let anchor = AnchorView()
        anchor.action = action
        let host = NSHostingView(rootView: AnyView(
            Button { anchor.action?(anchor) } label: {
                Image(systemName: "square.and.arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 18)
            }
            .buttonStyle(BarTextButtonStyle(prominent: false))
            .help(help)
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        anchor.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: anchor.leadingAnchor), host.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
            host.topAnchor.constraint(equalTo: anchor.topAnchor), host.bottomAnchor.constraint(equalTo: anchor.bottomAnchor),
        ])
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class AnchorView: NSView {
        var action: ((NSView) -> Void)?
        override var intrinsicContentSize: NSSize { NSSize(width: 46, height: 32) }
    }
}
