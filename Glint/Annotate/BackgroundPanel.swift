import AppKit
import SwiftUI

private typealias W = VideoEditorWindowController

/// Saving and deleting background presets. The screenshot and video editors share one list.
enum BackgroundPresets {
    /// Asks for a name, then saves `style`.
    static func save(_ style: BackgroundStyle) {
        var style = style
        let number = BackgroundStyle.presets.count + 1
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Name this background preset."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Preset \(number)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        style.name = name.isEmpty ? "Preset \(number)" : name
        style.expansion = nil
        BackgroundStyle.presets.append(style)
    }

    static func confirmDelete(_ index: Int) {
        var presets = BackgroundStyle.presets
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
    }
}

/// The screenshot editor's Background mode (sidebar): presets, fills, and padding, inset, shadow, corners,
/// alignment and ratio.
struct BackgroundPanel: View {
    @Bindable var doc: AnnotationDocument
    @State private var showAllGradients = false
    @State private var wallpaperLoaded = false
    @State private var presets = BackgroundStyle.presets
    @State private var showWallpapers = false
    @State private var customPaths: [String] = UserDefaults.standard.stringArray(forKey: "background.customImages") ?? []
    private let images = BackgroundImages.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text("Put the screenshot on a backdrop, with padding, shadow and round corners.")
                        .font(.system(size: 12)).foregroundStyle(Color(white: 0.55)).fixedSize(horizontal: false, vertical: true)
                }
                presetRow
                noneButton
                gradientSection
                wallpaperSection.id(wallpaperLoaded)
                colorSection
                Divider().overlay(W.line).padding(.vertical, 2)
                sliders
            }
            .padding(EdgeInsets(top: 22, leading: 22, bottom: 20, trailing: 22))
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity)
        .task {
            await images.prepare()
            wallpaperLoaded = true
        }
    }

    // MARK: Sections

    /// "Presets": a drop-down like Glint's other ones, with the saved presets, Save, and Delete.
    private var presetRow: some View {
        Menu {
            if presets.isEmpty { Text("No presets yet") }
            ForEach(Array(presets.enumerated()), id: \.offset) { i, preset in
                Button(preset.name ?? "Preset \(i + 1)") { apply(preset) }
            }
            Divider()
            Button("Save Current Background as Preset…", action: savePreset).disabled(doc.background == nil)
            if !presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(Array(presets.enumerated()), id: \.offset) { i, preset in
                        Button(preset.name ?? "Preset \(i + 1)") { confirmDelete(i) }
                    }
                }
            }
        } label: {
            Text("Presets")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Apply, save or delete background presets")
    }

    private var noneButton: some View {
        Button {
            // None keeps the slider values and shows no backdrop (transparent).
            if var bg = doc.background { bg.fill = .transparent; doc.background = bg }
        } label: {
            let none = doc.background == nil || doc.background?.fill == .transparent
            Text("None").font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(none ? W.blue : W.box))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("No background")
    }

    private var gradientSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Gradients")
                Spacer()
                Button { showAllGradients.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(showAllGradients ? "Show less" : "Show more")
                        Image(systemName: showAllGradients ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Color(white: 0.62))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 9), count: 5), spacing: 10) {
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
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 9), count: 5), alignment: .leading, spacing: 10) {
                Swatch(selected: doc.background?.fill == .wallpaper) { imageFill(images.wallpaper) } action: { select(.wallpaper) }
                    .help("Desktop wallpaper")
                ForEach(customPaths, id: \.self) { path in
                    Swatch(selected: doc.background?.fill == .customImage(path)) {
                        imageFill(images.thumbnail(path) ?? images.image(for: .customImage(path)))
                    } action: { select(.customImage(path)) }
                    .contextMenu { Button("Remove") { removeCustomImage(path) } }
                }
                Button { showWallpapers = true } label: {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Color(white: 0.55))
                        .frame(width: 38, height: 38)
                        .overlay(Image(systemName: "plus").foregroundStyle(Color(white: 0.7)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a macOS wallpaper or your own image")
                .popover(isPresented: $showWallpapers, arrowEdge: .trailing) { wallpaperPicker }
            }
            if isImageFill {
                // How blurred the wallpaper or image is (its brightness is the Brightness slider).
                HStack(spacing: 8) {
                    Text("Blur").font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62)).frame(width: 34, alignment: .leading)
                    ChoiceButtons(titles: ["None", "Light", "Medium", "Strong"], selected: blurLevel,
                                  helps: ["Sharp", "A little blurred", "Blurred", "Very blurred"]) { setBlur($0) }
                }
                .padding(.top, 4)
            }
        }
    }

    /// The "+" popover: the macOS wallpapers on this Mac, or any picture.
    private var wallpaperPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("macOS Wallpapers").font(.system(size: 12.5, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 8) {
                ForEach(BackgroundImages.builtInWallpapers, id: \.path) { wallpaper in
                    Button { addImage(wallpaper.path) } label: {
                        imageFill(images.thumbnail(wallpaper.thumbnail))
                            .frame(width: 64, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(URL(fileURLWithPath: wallpaper.path).deletingPathExtension().lastPathComponent)
                }
            }
            Divider()
            Button("Choose Image…", action: chooseCustomImage)
        }
        .padding(14)
        .frame(width: 310)
    }

    private var isImageFill: Bool {
        switch doc.background?.fill {
        case .wallpaper, .customImage, .blurred: true
        default: false
        }
    }

    private var blurLevel: Int {
        if case .blurred = doc.background?.fill { return 3 }
        return doc.background?.blur ?? 0
    }

    private func setBlur(_ level: Int) {
        guard var bg = doc.background else { return }
        // The old blurred-wallpaper fills become the wallpaper with a blur level.
        if case .blurred = bg.fill { bg.fill = .wallpaper }
        bg.blur = level
        doc.background = bg
        BackgroundStyle.lastUsed = bg
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Plain color")
            colorRow(BackgroundPalette.colorsDark) {
                Button { select(.transparent) } label: {
                    Checker().frame(width: 18, height: 18).clipShape(Circle())
                        .overlay(Circle().strokeBorder(doc.background?.fill == .transparent ? Color.white : .white.opacity(0.2),
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
                        .overlay(Circle().strokeBorder(selected ? Color.white : .white.opacity(0.15), lineWidth: selected ? 2 : 0.5))
                }
                .buttonStyle(.plain)
            }
            trailing()
        }
    }

    /// Two columns: labels start either at the left edge or at the second column; rows 14pt apart.
    private var sliders: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeledSlider("Padding", value: binding(\.padding), range: BackgroundStyle.maxPadding)
            HStack(alignment: .top, spacing: 16) {
                labeledSlider("Inset", value: binding(\.inset), range: BackgroundStyle.maxInset)
                    .disabled(doc.isWindowCapture)
                // A window capture already has its own shadow and rounded corners.
                labeledSlider("Corners", value: binding(\.corners), range: BackgroundStyle.maxCornerPercent).disabled(doc.isWindowCapture)
            }
            HStack(alignment: .top, spacing: 16) {
                BrightnessSlider(value: Binding(get: { doc.background?.brightness ?? 1 }, set: { value in
                    var bg = doc.background ?? BackgroundStyle(fill: .transparent)
                    bg.brightness = abs(value - 1) < 0.005 ? nil : value
                    doc.background = bg
                    BackgroundStyle.lastUsed = bg
                }))
                .frame(maxWidth: .infinity)
                .disabled(doc.background == nil || doc.background?.fill == .transparent)
                labeledSlider("Shadow", value: binding(\.shadow), range: BackgroundStyle.maxShadow).disabled(doc.isWindowCapture)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Ratio")
                    Picker("", selection: binding(\.ratio)) {
                        ForEach(BackgroundStyle.Ratio.allCases) { Text($0.menuTitle).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Toggle("Auto-balance", isOn: binding(\.autoBalance)).toggleStyle(.checkbox).font(.system(size: 12.5))
                        .disabled(doc.isWindowCapture)
                        .help("The screenshot's edge color fades into the background around it")
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        Text(text).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
    }

    private func labeledSlider(_ title: String, value: Binding<CGFloat>, range: CGFloat) -> some View {
        ValueSlider(title: title, value: value, range: range).frame(maxWidth: .infinity)
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

    private func confirmDelete(_ index: Int) {
        BackgroundPresets.confirmDelete(index)
        presets = BackgroundStyle.presets
    }

    /// "+": asks for a name, then saves the current background as a preset.
    private func savePreset() {
        guard let bg = doc.background else { return }
        BackgroundPresets.save(bg)
        presets = BackgroundStyle.presets
    }

    /// "+" → Choose Image…: any picture file.
    private func chooseCustomImage() {
        showWallpapers = false
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        addImage(path)
    }

    /// Adds a picture to the Wallpapers row (remembered for every editor) and uses it.
    private func addImage(_ path: String) {
        showWallpapers = false
        if !customPaths.contains(path) { customPaths.append(path) }
        UserDefaults.standard.set(customPaths, forKey: "background.customImages")
        select(.customImage(path))
    }

    private func removeCustomImage(_ path: String) {
        customPaths.removeAll { $0 == path }
        UserDefaults.standard.set(customPaths, forKey: "background.customImages")
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
                    .strokeBorder(selected ? Color.white : .clear, lineWidth: 2).padding(-3))
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

/// Title and value (click it to type one) over the editor's slider.
private struct ValueSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
                Spacer(minLength: 4)
                EditableValue(text: "\(Int((value * range).rounded()))",
                              value: Binding(get: { Double(value) }, set: { value = CGFloat($0) }), range: 0...1, scale: Double(range))
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            StepSlider(value: Binding(get: { Double(value) }, set: { value = CGFloat($0) }), range: 0...1, ticks: 5)
        }
    }
}

/// Brightness of the backdrop: 50…150%, 100% in the middle.
private struct BrightnessSlider: View {
    @Binding var value: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Brightness").font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
                Spacer(minLength: 4)
                EditableValue(text: "\(Int((value * 100).rounded()))%", value: Binding(get: { Double(value) }, set: { value = CGFloat($0) }),
                              range: 0.5...1.5, scale: 100)
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
            }
            StepSlider(value: Binding(get: { Double(value) }, set: { value = CGFloat($0) }), range: 0.5...1.5, ticks: 5)
                .help("Darker or brighter backdrop (100% = as it is)")
        }
    }
}
