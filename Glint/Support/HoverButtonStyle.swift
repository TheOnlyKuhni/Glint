import SwiftUI

/// The editors' plain buttons: hovering brightens the control (and grows it by `lift`, for small icons), pressing
/// dims it and pushes it in, starting from the hovered state.
struct HoverButtonStyle: ButtonStyle {
    var lift: CGFloat = 1
    func makeBody(configuration: Configuration) -> some View { HoverButtonBody(configuration: configuration, lift: lift) }
}

private struct HoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let lift: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let hovered = hovering && enabled
        configuration.label
            .brightness(configuration.isPressed ? -0.05 : (hovered ? 0.09 : 0))
            .scaleEffect(configuration.isPressed ? 0.95 : (hovered ? lift : 1))
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.spring(response: 0.22, dampingFraction: 0.65), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}
