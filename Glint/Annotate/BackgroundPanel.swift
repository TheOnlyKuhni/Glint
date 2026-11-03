import AppKit
import SwiftUI

/// Left sidebar of the Annotate editor for the Background tool.
struct BackgroundPanel: View {
    @Bindable var doc: AnnotationDocument
    @State private var showAllGradients = false
    @State private var wallpaperLoaded = false
    @State private var presets = BackgroundStyle.presets
    @State private var showPresets = false
    @State private var editingPresets = false
    @State private var customPaths: [String] = UserDefaults.standard.stringArray(forKey: "background.customImages") ?? []
    private let images = BackgroundImages.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                presetRow
                noneButton
                gradientSection
                wallpaperSection.id(wallpaperLoaded)
                blurredSection.id(wallpaperLoaded)
                colorSection
                Divider().padding(.vertical, 2)
                sliders
            }
            .padding(14)
        }
        .scrollIndicators(.never)
        .frame(width: 250)
        .background(Color(.displayP3, red: 0x32 / 255.0, green: 0x32 / 255.0, blue: 0x35 / 255.0))
        .task {
            await images.prepare()
            wallpaperLoaded = true
            // Blurred variants are expensive; build them off the first frame.
            _ = images.image(for: .blurred(0)); _ = images.image(for: .blurred(1)); _ = images.image(for: .blurred(2))
            wallpaperLoaded.toggle(); wallpaperLoaded = true
        }
    }

    // MARK: Sections

    /// "Presets…" opens a list of the saved presets; "Edit Presets" shows a red minus beside each, which deletes it
    /// after a confirmation.
    private var presetRow: some View {
        HStack(spacing: 8) {
            Button { editingPresets = false; showPresets.toggle() } label: {
                HStack {
                    Text("Presets…")
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.1)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .popover(isPresented: $showPresets, arrowEdge: .bottom) { presetList }
            Button { savePreset() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Save the current background as a preset")
                .disabled(doc.background == nil)
        }
    }

    private var noneButton: some View {
        Button {
            // None keeps the slider values and shows no backdrop (transparent).
            if var bg = doc.background { bg.fill = .transparent; doc.background = bg }
        } label: {
            Text("None").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(doc.background == nil || doc.background?.fill == .transparent ? Color.accentColor : .clear, lineWidth: 2.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("No background")
    }

    private var gradientSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Gradients").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { showAllGradients.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(showAllGradients ? "Show less" : "Show more")
                        Image(systemName: showAllGradients ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 9), count: 5), spacing: 9) {
                ForEach(0..<(showAllGradients ? BackgroundPalette.count : 10), id: \.self) { i in
                    Swatch(selected: doc.background?.fill == .gradient(i)) {
                        Image(nsImage: BackgroundPalette.swatch(i)).resizable()
                    } action: { select(.gradient(i)) }
                }
            }
        }
    }

    private var wallpaperSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Wallpapers")
            HStack(spacing: 9) {
                Swatch(selected: doc.background?.fill == .wallpaper) { imageFill(images.wallpaper) } action: { select(.wallpaper) }
                    .help("Desktop wallpaper")
                ForEach(customPaths, id: \.self) { path in
                    Swatch(selected: doc.background?.fill == .customImage(path)) {
                        imageFill(images.image(for: .customImage(path)))
                    } action: { select(.customImage(path)) }
                }
                Button(action: addCustomImage) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .overlay(Image(systemName: "plus").foregroundStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help("Add a custom image")
            }
        }
    }

    private var blurredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Blurred")
            HStack(spacing: 9) {
                ForEach(0..<3, id: \.self) { v in
                    Swatch(selected: doc.background?.fill == .blurred(v)) { imageFill(images.image(for: .blurred(v))) }
                        action: { select(.blurred(v)) }
                }
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Plain color")
            colorRow(BackgroundPalette.colorsDark) {
                Button { select(.transparent) } label: {
                    Checker().frame(width: 18, height: 18).clipShape(Circle())
                        .overlay(Circle().strokeBorder(doc.background?.fill == .transparent ? Color.accentColor : .white.opacity(0.2),
                                                       lineWidth: doc.background?.fill == .transparent ? 2 : 0.5))
                }
                .buttonStyle(.plain).help("Transparent")
            }
            colorRow(BackgroundPalette.colorsLight) {
                Button {
                    ColorPanelBridge.shared.open { select(.color(AnnotationColor($0).hex)) }
                } label: {
                    Image(nsImage: SwatchImage.colorWheel(diameter: 18)).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Custom color")
            }
        }
    }

    private func colorRow(_ colors: [UInt32], @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 7) {
            ForEach(colors, id: \.self) { hex in
                let selected = doc.background?.fill == .color(hex)
                Button { select(.color(hex)) } label: {
                    Circle().fill(Color(nsColor: BackgroundPalette.nsColor(hex))).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .white.opacity(0.15), lineWidth: selected ? 2 : 0.5))
                }
                .buttonStyle(.plain)
            }
            trailing()
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledSlider("Padding", value: binding(\.padding), range: BackgroundStyle.maxPadding)
            HStack(alignment: .bottom, spacing: 12) {
                labeledSlider("Inset", value: binding(\.inset), range: BackgroundStyle.maxInset)
                    .disabled(doc.isWindowCapture)
                Toggle("Auto-balance", isOn: binding(\.autoBalance)).toggleStyle(.checkbox).font(.system(size: 12))
                    .disabled(doc.isWindowCapture)
            }
            HStack(spacing: 12) {
                // A window capture already has its own shadow and rounded corners.
                labeledSlider("Shadow", value: binding(\.shadow), range: BackgroundStyle.maxShadow).disabled(doc.isWindowCapture)
                labeledSlider("Corners", value: binding(\.corners), range: BackgroundStyle.maxCornerPercent).disabled(doc.isWindowCapture)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Alignment")
                    Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(0..<3, id: \.self) { row in
                            GridRow {
                                ForEach(0..<3, id: \.self) { col in
                                    alignmentCell(row * 3 + col)
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("Ratio")
                    Picker("", selection: binding(\.ratio)) {
                        ForEach(BackgroundStyle.Ratio.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
        }

    }

    private func alignmentCell(_ index: Int) -> some View {
        let selected = doc.background?.alignment == index
        return Button {
            var bg = doc.background ?? BackgroundStyle(fill: .transparent)
            bg.alignment = index
            doc.background = bg
        } label: {
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary, lineWidth: 1)
                .frame(width: 24, height: 18)
                .overlay(alignment: Alignment(horizontal: [.leading, .center, .trailing][index % 3], vertical: [.top, .center, .bottom][index / 3])) {
                    RoundedRectangle(cornerRadius: 1.5).fill(selected ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(width: 10, height: 7).padding(3)
                }
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func labeledSlider(_ title: String, value: Binding<CGFloat>, range: CGFloat) -> some View {
        ValueSlider(title: title, value: value, range: range)
    }

    @ViewBuilder
    private func imageFill(_ image: CGImage?) -> some View {
        if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { Color.gray.opacity(0.3) }
    }

    private func binding<V>(_ keyPath: WritableKeyPath<BackgroundStyle, V>) -> Binding<V> {
        Binding(
            get: { (doc.background ?? BackgroundStyle(fill: .transparent))[keyPath: keyPath] },
            set: { newValue in
                // With "None", moving a slider starts a transparent background.
                var bg = doc.background ?? BackgroundStyle(fill: .transparent)
                bg[keyPath: keyPath] = newValue
                // Window captures: dragging Padding to 0 switches to the transparent background.
                if doc.isWindowCapture, keyPath == \BackgroundStyle.padding, (newValue as? CGFloat) == 0 { bg.fill = .transparent }
                doc.background = bg
                BackgroundStyle.lastUsed = bg
            }
        )
    }

    private func select(_ fill: BackgroundStyle.Fill) {
        var bg = doc.background ?? BackgroundStyle(fill: fill)
        bg.fill = fill
        doc.background = bg
        BackgroundStyle.lastUsed = bg
    }

    private func apply(_ preset: BackgroundStyle) {
        var preset = preset
        preset.name = nil
        doc.background = preset
        BackgroundStyle.lastUsed = preset
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if presets.isEmpty {
                Text("No presets yet").foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(Array(presets.enumerated()), id: \.offset) { i, preset in
                HStack(spacing: 8) {
                    if editingPresets {
                        Button { confirmDelete(i) } label: {
                            Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color(red: 0.93, green: 0.27, blue: 0.27)).font(.system(size: 15))
                        }
                        .buttonStyle(.plain)
                        .help("Delete preset")
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    PresetRowButton(title: preset.name ?? "Preset \(i + 1)", enabled: !editingPresets) {
                        apply(preset)
                        showPresets = false
                    }
                }
            }
            if !presets.isEmpty {
                Divider().padding(.vertical, 4)
                PresetRowButton(title: editingPresets ? "Done" : "Edit Presets", enabled: true) {
                    withAnimation(.easeOut(duration: 0.15)) { editingPresets.toggle() }
                }
            }
        }
        .padding(6)
        .frame(width: 220, alignment: .leading)
    }

    private func confirmDelete(_ index: Int) {
        guard presets.indices.contains(index) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(presets[index].name ?? "Preset \(index + 1)")”?"
        alert.informativeText = "This preset will be removed. This can't be undone."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        presets.remove(at: index)
        BackgroundStyle.presets = presets
        // Keep the Screenshots setting "Background preset" pointing at the same preset.
        let chosen = Defaults[Prefs.backgroundPreset]
        if chosen == index { Defaults[Prefs.backgroundPreset] = -1 } else if chosen > index { Defaults[Prefs.backgroundPreset] = chosen - 1 }
        if presets.isEmpty { editingPresets = false }
    }

    /// "+": asks for a name, then saves the current background as a preset.
    private func savePreset() {
        guard var bg = doc.background else { return }
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Name this background preset."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Preset \(presets.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        bg.name = name.isEmpty ? "Preset \(presets.count + 1)" : name
        bg.expansion = nil
        presets.append(bg)
        BackgroundStyle.presets = presets
    }

    private func addCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        if !customPaths.contains(path) { customPaths.append(path) }
        UserDefaults.standard.set(customPaths, forKey: "background.customImages")
        select(.customImage(path))
    }
}

/// Opens the system color panel and reports picked colors.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var handler: ((NSColor) -> Void)?

    func open(_ handler: @escaping (NSColor) -> Void) {
        self.handler = handler
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ sender: NSColorPanel) { handler?(sender.color) }
}

private struct Swatch<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: () -> Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
        }
        .buttonStyle(.plain)
    }
}

private struct Checker: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 4.5
            for r in 0..<Int(size.height / s) + 1 {
                for c in 0..<Int(size.width / s) + 1 where (r + c).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(c) * s, y: CGFloat(r) * s, width: s, height: s)), with: .color(.gray))
                }
            }
        }
        .background(Color.white)
    }
}

/// Title + slider; while hovered or dragged, the value (real units) appears right-aligned on the title row in a
/// light gray rounded box.
private struct ValueSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: CGFloat
    @State private var hovering = false
    @State private var dragging = false
    @State private var typing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                EditableValue(text: "\(Int((value * range).rounded()))",
                              value: Binding(get: { Double(value) }, set: { value = CGFloat($0) }), range: 0...1,
                              scale: Double(range), onEditing: { typing = $0 })
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.13)))
                    .opacity(hovering || dragging || typing ? 1 : 0)
            }
            Slider(value: $value, in: 0...1) { editing in dragging = editing }
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A menu-like row in the presets list: highlights blue on hover, like a menu item.
private struct PresetRowButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).frame(height: 24)
                .foregroundStyle(hovered && enabled ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovered && enabled ? Color.accentColor : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovered = $0 }
    }
}
