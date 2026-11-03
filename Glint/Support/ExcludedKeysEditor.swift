import SwiftUI

/// The keys keystroke labels never show: one removable chip per key, and "Add Key…", which takes the next key
/// pressed (with its modifiers). `suggestions` (the editor: the shortcuts and keys of this recording) are offered in
/// a menu.
struct ExcludedKeysEditor: View {
    @Binding var keys: [ExcludedKey]
    var suggestions: [ExcludedKey] = []
    @State private var listening = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !keys.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(keys, id: \.self) { key in
                        HStack(spacing: 4) {
                            Text(key.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Button { keys.removeAll { $0 == key } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Show \(key.label) again")
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.12)))
                    }
                }
            }
            HStack(spacing: 8) {
                Button { listening ? stop() : listen() } label: {
                    Text(listening ? "Press a key…" : "Add Key…")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(listening ? 0.2 : 0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(listening ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(listening ? "Press the key or shortcut to hide (click again to cancel)" : "Hide a key or shortcut: click, then press it")
                let offered = suggestions.filter { !keys.contains($0) }
                if !offered.isEmpty {
                    Menu {
                        ForEach(offered, id: \.self) { key in Button(key.label) { keys.append(key) } }
                    } label: {
                        Text("From This Recording").font(.system(size: 12.5, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Hide one of the shortcuts or keys pressed in this recording")
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private func listen() {
        listening = true
        // Glint's own shortcuts can be hidden too: they don't fire meanwhile.
        ShortcutManager.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = ExcludedKey(code: Int(event.keyCode), flags: event.modifierFlags.rawValue, chars: event.charactersIgnoringModifiers ?? "")
            if !keys.contains(key) { keys.append(key) }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if listening { ShortcutManager.shared.setSuspended(false) }
        monitor = nil
        listening = false
    }
}
