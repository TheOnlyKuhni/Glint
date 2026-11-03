import SwiftUI

/// A slider's value label that turns into a text field when clicked, so an exact value can be typed. Return or
/// clicking elsewhere applies it (clamped to the slider's range), Esc keeps the old value. `scale` maps the stored
/// value to the shown number (100 for percentages of 0…1).
struct EditableValue: View {
    let text: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var scale: Double = 1
    var decimals = 0
    /// Told when typing starts and ends (e.g. to keep a hover-only label visible meanwhile).
    var onEditing: ((Bool) -> Void)? = nil
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// Watches clicks while typing: one anywhere but in the field applies the value (a click on a plain area doesn't
    /// take the focus away, so the field wouldn't notice on its own).
    @State private var clickMonitor: Any?

    var body: some View {
        if editing {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 46)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.12)))
                .focused($focused)
                .onSubmit(commit)
                .onExitCommand { editing = false }
                .onChange(of: focused) { _, now in if !now { commit() } }
                .onAppear {
                    onEditing?(true)
                    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
                        if let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                           editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) { return event }
                        DispatchQueue.main.async { commit() }
                        return event
                    }
                    // Focus only takes once the field is in the window; then its text is selected to type over.
                    DispatchQueue.main.async {
                        focused = true
                        DispatchQueue.main.async { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
                    }
                }
                .onDisappear {
                    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                    clickMonitor = nil
                    onEditing?(false)
                }
        } else {
            Text(text)
                .contentShape(Rectangle())
                .onTapGesture {
                    draft = String(format: "%.\(decimals)f", value * scale)
                    editing = true
                }
                .pointerStyle(.horizontalText)
                .help("Click to type a value")
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        // "150", "150%", "1,5 s": the number is what counts.
        let number = draft.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let typed = Double(number) else { return }
        value = min(max(typed / scale, range.lowerBound), range.upperBound)
    }
}
