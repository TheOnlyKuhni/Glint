import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The "Record shortcut" button used in the Shortcuts settings pane.
struct ShortcutRecorder: View {
    let action: AppAction
    @State private var isRecording = false
    @State private var isHovering = false
    @State private var monitor: Any?

    private var manager: ShortcutManager { .shared }

    var body: some View {
        let combo = manager.shortcut(for: action)
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            ZStack {
                if isRecording {
                    Text("Type shortcut…").foregroundStyle(.secondary)
                } else if let combo {
                    Text(combo.displayString).fontWeight(.semibold).foregroundStyle(.primary)
                } else {
                    Text("Record shortcut").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .frame(width: 212, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(combo != nil && !isRecording ? Color.primary.opacity(0.28) : Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 2)
            )
            .overlay(alignment: .trailing) {
                if combo != nil, isHovering, !isRecording {
                    Button { manager.set(nil, for: action) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        manager.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bareKey = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            switch Int(event.keyCode) {
            case kVK_Escape:
                stopRecording()
            case kVK_Delete where bareKey, kVK_ForwardDelete where bareKey:
                manager.set(nil, for: action)
                stopRecording()
            default:
                if let combo = KeyCombo(event: event), combo.isValidGlobalShortcut {
                    manager.set(combo, for: action)
                    stopRecording()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        manager.setSuspended(false)
    }
}
