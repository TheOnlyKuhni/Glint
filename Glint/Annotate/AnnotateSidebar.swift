import AppKit
import SwiftUI

private typealias W = VideoEditorWindowController

/// What the screenshot editor's left side shows: the mode rail picks one, the sidebar holds its settings. The
/// drawing tools stay in the toolbar in every mode except Crop (they rest while cropping).
enum AnnotateMode: CaseIterable {
    case annotate, background, add, crop

    var title: String {
        switch self {
        case .annotate: "Annotate"
        case .background: "Background"
        case .add: "Add Image"
        case .crop: "Crop & Resize"
        }
    }

    var symbol: String {
        switch self {
        case .annotate: "pencil.tip.crop.circle"
        case .background: "photo.artframe"
        case .add: "photo.badge.plus"
        case .crop: "crop"
        }
    }

    var help: String {
        switch self {
        case .annotate: "Annotate: color, size and style of the tool or the selected object"
        case .background: "Background (B): put the screenshot on a backdrop"
        case .add: "Add Image: a screenshot or an image file on top"
        case .crop: "Crop & Resize (K)"
        }
    }
}

@Observable
final class AnnotateEditorModel {
    var mode: AnnotateMode = .annotate
}

// MARK: - Mode rail

/// The column of mode buttons on the far left: 18pt symbols, the selected one on a blue rounded square. Hovering a
/// button lifts it: a soft plate fades in and the symbol grows a little.
struct AnnotateModeRail: View {
    let model: AnnotateEditorModel
    let select: (AnnotateMode) -> Void

    var body: some View {
        VStack(spacing: 14) {
            ForEach(AnnotateMode.allCases, id: \.self) { mode in
                RailButton(symbol: mode.symbol, title: mode.title, help: mode.help, selected: model.mode == mode) { select(mode) }
            }
            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(W.base)
    }
}

private struct RailButton: View {
    let symbol: String
    let title: String
    let help: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected || hovering ? Color.white : Color(white: 0.55))
                .scaleEffect(hovering && !selected ? 1.12 : 1)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? W.blue : Color.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(RailPressStyle())
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}

/// Pressing shrinks the button a little.
private struct RailPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// MARK: - Sidebar

/// What the sidebar's controls do (the editor applies them, so undo, the selection and the canvas stay in step).
struct AnnotateSidebarActions {
    var setColor: (AnnotationColor) -> Void
    var customColor: () -> Void
    var setThickness: (Int) -> Void
    var setFontSize: (CGFloat) -> Void
    var setArrowStyle: (ArrowStyle) -> Void
    var setTextStyle: (TextStyle) -> Void
    var setRedactMode: (RedactMode) -> Void
    var setSpotlightShape: (SpotlightShape) -> Void
    var setCounterStyle: (CounterStyle) -> Void
    var setCounterStart: (Int) -> Void
    var setCounterSize: (CGFloat) -> Void
    var setAmount: (CGFloat) -> Void
    var setSpotlightBrightness: (CGFloat) -> Void
    var setSpotlightRest: (CGFloat) -> Void
    var setSpotlightKeepsAnnotations: (Bool) -> Void
    var setSpotlightSoftness: (CGFloat) -> Void
    var setSpotlightBorder: (Bool) -> Void
    var setMagnifier: ((AnnotationDocument) -> Void) -> Void
    var setEmoji: (String) -> Void
    var setEmojiSize: (CGFloat) -> Void
    var takeScreenshot: () -> Void
    var chooseImage: () -> Void
    var setCropRatio: (CropState.Ratio) -> Void
    var setCropFill: (CropState.Fill) -> Void
    var customCropFill: () -> Void
    var rotate: () -> Void
    var flip: () -> Void
    var cancelCrop: () -> Void
    var applyCrop: () -> Void
}

struct AnnotateSidebar: View {
    let model: AnnotateEditorModel
    let doc: AnnotationDocument
    /// Crop & Resize's state while cropping.
    let crop: () -> CropState?
    let actions: AnnotateSidebarActions

    var body: some View {
        Group {
            switch model.mode {
            case .annotate: scrolling { AnnotateOptionsPanel(doc: doc, actions: actions) }
            case .background: BackgroundPanel(doc: doc)
            case .add: scrolling { AddImagePanel(actions: actions) }
            case .crop:
                if let state = crop() { CropPanel(state: state, doc: doc, imageFill: { $0.color(for: doc.baseImage) }, actions: actions) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(W.base)
        .environment(\.colorScheme, .dark)
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            content()
                .padding(EdgeInsets(top: 22, leading: 22, bottom: 20, trailing: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }
}

/// The sidebar's title: the mode or tool in white, a short line of what it does under it.
private struct PanelTitle: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Color(white: 0.55)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }
}

/// A square-ish choice in the sidebar's look: dark box, blue when selected, lighter while hovered.
private struct TileButton<Label: View>: View {
    let selected: Bool
    var height: CGFloat = 34
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: height)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? W.blue : (hovering ? Color(white: 0.21) : W.box)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Annotate

/// Annotate mode: the options of the tool picked in the toolbar, or of the selected object.
struct AnnotateOptionsPanel: View {
    let doc: AnnotationDocument
    let actions: AnnotateSidebarActions

    private var tool: AnnotateTool { doc.selected.map { AnnotateTool(drawing: $0.kind) } ?? doc.tool }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let selected = doc.selected, case .image = selected.kind {
                PanelTitle(title: "Selected Image", subtitle: "Drag it to move it, drag its corners to resize it. ⌫ removes it.")
            } else {
                PanelTitle(title: doc.selected != nil ? "Selected \(tool.title)" : tool.title,
                           subtitle: doc.selected != nil ? "Changes apply to the selected object." : tool.modifierHint)
            }
            if tool == .select, doc.selected == nil {
                InfoBox { Text("Pick a tool in the toolbar to draw, or click an object to change its color, size and style.") }
            }
            if hasColor { colorSection }
            if tool == .text { fontSizeSection }
            if hasThickness { thicknessSection }
            styleSection
            if tool == .redact { amountSection }
            if tool == .spotlight { spotlightSection }
            if tool == .magnifier { magnifierSection }
            if tool == .counter { counterSection }
            if tool == .emoji { emojiSection }
        }
    }

    private var hasColor: Bool { tool.usesColor }

    private static let emojis = ["👍", "👎", "👀", "✅", "❌", "⚠️", "❗️", "❓", "💡", "🔥", "⭐️", "❤️",
                                 "😀", "😂", "😍", "🤔", "😮", "😢", "😡", "🎉", "🙏", "👏", "💯", "🚀",
                                 "👉", "👈", "👆", "👇", "✋", "🤝", "🐛", "🔒", "🔑", "📌", "🔍", "💬"]

    /// The emoji a click places: a grid of common ones, or any other typed or picked in the field; and its size.
    private var emojiSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Emoji", value: doc.emoji).padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 6), spacing: 4) {
                ForEach(Self.emojis, id: \.self) { emoji in
                    TileButton(selected: doc.emoji == emoji, height: 34, help: emoji) { actions.setEmoji(emoji) } label: {
                        Text(emoji).font(.system(size: 20))
                    }
                }
            }
            EmojiField(current: doc.emoji, commit: actions.setEmoji)
            let size = Binding(get: { Double(doc.emojiSize) }, set: { actions.setEmojiSize(CGFloat($0)) })
            InspectorHeader("Size", value: "\(Int(doc.emojiSize)) pt").padding(.top, 6)
            StepSlider(value: size, range: 24...240, step: 4, ticks: 5).help("How big new emoji are (drag a placed one's corners to resize it)")
        }
    }
    private var hasThickness: Bool { [.rectangle, .ellipse, .line, .arrow, .counter, .draw, .highlighter].contains(tool) }

    private static let colorNameMap: [UInt32: String] = [
        0x000000: "Black", 0xE5484A: "Red", 0xF09235: "Orange", 0xFAE24C: "Yellow", 0x70D363: "Green",
        0x66CCC1: "Teal", 0x3478F6: "Blue", 0x8254F6: "Purple", 0xEA456D: "Pink", 0xFFFFFF: "White",
    ]

    private var colorSection: some View {
        let name = Self.colorNameMap[doc.color.hex] ?? "Custom"
        return VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Color", value: name).padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(AnnotationColor.palette, id: \.hex) { color in
                    ColorDot(color: Color(nsColor: color.nsColor), selected: doc.color == color, help: Self.colorNameMap[color.hex] ?? "") {
                        actions.setColor(color)
                    }
                }
                let custom = !AnnotationColor.palette.contains(doc.color)
                Button(action: actions.customColor) {
                    Image(nsImage: SwatchImage.colorWheel(diameter: 26)).resizable().frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(custom ? Color.white : .clear, lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .help("Custom color…")
            }
        }
    }

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Font size", value: "\(Int(doc.fontSize)) pt").padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(AnnotationStyle.fontSizes, id: \.self) { size in
                    TileButton(selected: doc.fontSize == size, height: 28, help: "\(Int(size)) pt") { actions.setFontSize(size) } label: {
                        Text("\(Int(size))").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                    }
                }
            }
        }
    }

    private var thicknessSection: some View {
        // Counters share one size; the thickness steps pick it.
        let step = tool == .counter ? doc.shownCounter.thicknessStep : doc.thickness
        let widths = AnnotationStyle.thicknesses
        return VStack(alignment: .leading, spacing: 10) {
            InspectorHeader(tool == .counter ? "Size" : "Thickness", value: tool == .counter ? nil : "\(Int(widths[min(step, widths.count - 1)])) pt")
                .padding(.top, 6)
            HStack(spacing: 6) {
                ForEach(widths.indices, id: \.self) { i in
                    TileButton(selected: i == step, height: 32, help: "\(Int(widths[i])) pt") { actions.setThickness(i) } label: {
                        Capsule().fill(Color.white).frame(width: 18, height: max(1.5, widths[i] / 2.2)).rotationEffect(.degrees(-35))
                    }
                }
            }
        }
    }

    /// Text style samples show the current color, so the styles read as they will look; black and white (which
    /// would vanish on the tiles or in the white card) show as red.
    private var sampleColor: AnnotationColor {
        doc.color.isDark || doc.color.hex == 0xFFFFFF ? AnnotationColor(hex: 0xE5484A) : doc.color
    }

    @ViewBuilder private var styleSection: some View {
        switch tool {
        case .arrow:
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader("Style", value: doc.arrowStyle.title).padding(.top, 6)
                HStack(spacing: 6) {
                    ForEach(ArrowStyle.allCases, id: \.self) { style in
                        TileButton(selected: doc.arrowStyle == style, height: 40, help: style.title) { actions.setArrowStyle(style) } label: {
                            Image(nsImage: OptionGlyph.arrowPreview(style)).renderingMode(.template)
                        }
                    }
                }
            }
        case .text:
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader("Style", value: doc.textStyle.title).padding(.top, 6)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(TextStyle.allCases, id: \.self) { style in
                        TileButton(selected: doc.textStyle == style, height: 36, help: style.title) { actions.setTextStyle(style) } label: {
                            Image(nsImage: SwatchImage.textStyleSample(style, color: sampleColor))
                        }
                    }
                }
            }
        case .redact:
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader("Mode").padding(.top, 6)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(RedactMode.allCases, id: \.self) { mode in
                        TileButton(selected: doc.redactMode == mode, height: 34, help: mode.title) { actions.setRedactMode(mode) } label: {
                            HStack(spacing: 6) {
                                Image(nsImage: OptionGlyph.redact(mode)).renderingMode(.template)
                                Text(mode.title).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                    }
                }
            }
        case .spotlight:
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader("Shape", value: doc.spotlightShape.title).padding(.top, 6)
                HStack(spacing: 6) {
                    ForEach(SpotlightShape.allCases, id: \.self) { shape in
                        TileButton(selected: doc.spotlightShape == shape, height: 36, help: shape.title) { actions.setSpotlightShape(shape) } label: {
                            Image(nsImage: OptionGlyph.spotlight(shape)).renderingMode(.template)
                        }
                    }
                }
            }
        case .counter:
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader("Numbering").padding(.top, 6)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(CounterStyle.allCases, id: \.self) { style in
                        TileButton(selected: doc.shownCounter.style == style, height: 30, help: style.title) { actions.setCounterStyle(style) } label: {
                            Text(style.title).font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private var amountSection: some View {
        let binding = Binding(get: { Double(doc.redactAmount) }, set: { actions.setAmount(CGFloat($0)) })
        return VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Strength", percent: binding, range: 0...1).padding(.top, 6)
            StepSlider(value: binding, range: 0...1, ticks: 5).help("How strongly the area is obscured")
        }
    }

    /// Brightness inside the spotlight (125% by default) and of everything else; 100% leaves it as it is.
    private var spotlightSection: some View {
        let inside = Binding(get: { Double(doc.spotlightBrightness) }, set: { actions.setSpotlightBrightness(CGFloat($0)) })
        let rest = Binding(get: { Double(doc.spotlightRest) }, set: { actions.setSpotlightRest(CGFloat($0)) })
        return VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Spotlight brightness", percent: inside, range: 0.5...2).padding(.top, 6)
            StepSlider(value: inside, range: 0.5...2, step: 0.05, ticks: 7).help("Brighten or darken the spotlighted area (100% = unchanged)")
            InspectorHeader("Everything else", percent: rest, range: 0...1.5).padding(.top, 6)
            StepSlider(value: rest, range: 0...1.5, step: 0.05, ticks: 7).help("Brighten or darken the rest of the screenshot (100% = unchanged)")
            Toggle(isOn: Binding(get: { doc.spotlightKeepsAnnotations }, set: actions.setSpotlightKeepsAnnotations)) {
                Text("Exclude annotations").font(.system(size: 12.5)).foregroundStyle(.white)
            }
            .toggleStyle(.checkbox)
            .help("Arrows, text and other annotations outside the spotlight keep their brightness")
            let soft = Binding(get: { Double(doc.spotlightSoftness) }, set: { actions.setSpotlightSoftness(CGFloat($0)) })
            InspectorHeader("Soft edge", percent: soft, range: 0...1).padding(.top, 6)
            StepSlider(value: soft, range: 0...1, step: 0.05, ticks: 5).help("How gently the spotlight's edge fades into the rest (0% = a sharp edge)")
            Toggle(isOn: Binding(get: { doc.spotlightBorder }, set: actions.setSpotlightBorder)) {
                Text("Border").font(.system(size: 13.5)).foregroundStyle(.white)
            }
            .toggleStyle(BlueSwitch())
            .padding(.top, 6)
            .help("A line around the spotlight, in the color below")
            // The border's color, right under its switch (a spotlight has no color otherwise).
            if doc.spotlightBorder { colorSection }
        }
    }

    /// Callout or in place, shape, zoom, the callout's link, and what is enlarged.
    private var magnifierSection: some View {
        let zoom = Binding(get: { Double(doc.magnifierZoom) }, set: { z in actions.setMagnifier { $0.magnifierZoom = CGFloat(z) } })
        return VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Style", value: doc.magnifierStyle.title).padding(.top, 6)
            HStack(spacing: 6) {
                ForEach(MagnifierStyle.allCases, id: \.self) { style in
                    TileButton(selected: doc.magnifierStyle == style, height: 30, help: style.help) {
                        actions.setMagnifier { $0.magnifierStyle = style }
                    } label: {
                        Text(style.title).font(.system(size: 12, weight: .medium))
                    }
                }
            }
            InspectorHeader("Shape", value: doc.magnifierShape.title).padding(.top, 6)
            HStack(spacing: 6) {
                ForEach(MagnifierShape.allCases, id: \.self) { shape in
                    TileButton(selected: doc.magnifierShape == shape, height: 36, help: shape.title) {
                        actions.setMagnifier { $0.magnifierShape = shape }
                    } label: {
                        Image(systemName: shape.symbol).font(.system(size: 15, weight: .medium))
                    }
                }
            }
            InspectorHeader("Zoom", value: String(format: "%.1f×", doc.magnifierZoom)).padding(.top, 6)
            StepSlider(value: zoom, range: Double(MagnifierZoom.range.lowerBound)...Double(MagnifierZoom.range.upperBound), step: 0.25, ticks: 10)
                .help("How much the area is enlarged. You can also scroll over a selected magnifier.")
            if doc.magnifierStyle == .callout {
                InspectorHeader("Link", value: doc.magnifierLink.title).padding(.top, 6)
                HStack(spacing: 6) {
                    ForEach(MagnifierLink.allCases, id: \.self) { link in
                        TileButton(selected: doc.magnifierLink == link, height: 30, help: "What joins the area and its enlarged copy") {
                            actions.setMagnifier { $0.magnifierLink = link }
                        } label: {
                            Text(link.title).font(.system(size: 12, weight: .medium))
                        }
                    }
                }
            }
            Toggle(isOn: Binding(get: { doc.magnifierIncludesAnnotations }, set: { on in actions.setMagnifier { $0.magnifierIncludesAnnotations = on } })) {
                Text("Include annotations").font(.system(size: 12.5)).foregroundStyle(.white)
            }
            .toggleStyle(.checkbox)
            .padding(.top, 4)
            .help("Arrows, text and other annotations under the area are enlarged too")
            Toggle(isOn: Binding(get: { doc.magnifierSmooth }, set: { on in actions.setMagnifier { $0.magnifierSmooth = on } })) {
                Text("Smooth").font(.system(size: 12.5)).foregroundStyle(.white)
            }
            .toggleStyle(.checkbox)
            .help("Smooth scaling for photos. Off: every pixel stays sharp, best for text and interfaces.")
        }
    }

    private var counterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Starting number").font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
                Spacer()
                CounterStartField(value: doc.counter.start, commit: actions.setCounterStart)
            }
            .padding(.top, 6)
            let size = Binding(get: { Double(doc.shownCounter.size) }, set: { actions.setCounterSize(CGFloat($0)) })
            InspectorHeader("Exact size", percent: size, range: 0...1).padding(.top, 6)
            StepSlider(value: size, range: 0...1, ticks: 5).help("The size of every counter (the thickness steps pick common ones)")
        }
    }
}

/// A color in the palette: a 26pt dot with a white ring when picked.
private struct ColorDot: View {
    let color: Color
    let selected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? Color.white : (hovering ? Color.white.opacity(0.35) : .clear), lineWidth: 2))
                .scaleEffect(hovering && !selected ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Any other emoji: type or paste one, or pick it in the Character Viewer ("All Emoji…", which types into the field).
private struct EmojiField: View {
    let current: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Other emoji", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box))
                .focused($focused)
                .onChange(of: draft) { _, text in
                    // The last character typed or picked is the emoji.
                    if let last = text.last, String(last) != current { commit(String(last)) }
                }
            Button {
                focused = true
                DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
            } label: {
                Text("All Emoji…").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box))
            }
            .buttonStyle(.plain)
            .help("Pick any emoji in the Character Viewer")
        }
    }
}

/// The counters' starting number: applies on Return or when leaving the field.
private struct CounterStartField: View {
    let value: Int
    let commit: (Int) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 54, height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(W.box))
            .focused($focused)
            .onAppear { draft = "\(value)" }
            .onChange(of: value) { _, v in draft = "\(v)" }
            .onSubmit(apply)
            .onChange(of: focused) { _, now in if !now { apply() } }
    }

    private func apply() {
        if let n = Int(draft.filter(\.isNumber)), n >= 1 { commit(n) } else { draft = "\(value)" }
    }
}

// MARK: Add

/// Add Image mode: a screenshot or an image file goes on top of the screenshot as an object.
private struct AddImagePanel: View {
    let actions: AnnotateSidebarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(title: "Add Image", subtitle: "Put another screenshot or an image on top of this one.")
            BigActionButton(symbol: "camera.viewfinder", title: "Take Screenshot", shortcut: "⇧⌘I",
                            help: "Capture an area of the screen and add it", action: actions.takeScreenshot)
            BigActionButton(symbol: "folder", title: "Choose From File…", shortcut: "⌘I",
                            help: "Add an image file", action: actions.chooseImage)
            InfoBox { Text("The image is added as an object: drag it to move it, drag its corners to resize it. The canvas grows to fit it.") }
                .padding(.top, 6)
        }
    }
}

private struct BigActionButton: View {
    let symbol: String
    let title: String
    let shortcut: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: 22)
                Text(title).font(.system(size: 13.5, weight: .medium))
                Spacer()
                Text(shortcut).font(.system(size: 12)).foregroundStyle(Color(white: 0.55))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Color(white: 0.21) : W.box))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Crop

/// A group in the Crop & Resize panel: a divider (except for the first), its name and what it's for.
private struct CropSection: View {
    let title: String
    let subtitle: String
    var first = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !first { Rectangle().fill(W.line).frame(height: 1).padding(.bottom, 14) }
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Color(white: 0.55)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, first ? 0 : 10)
        .padding(.bottom, 2)
    }
}

/// Crop & Resize mode in three groups (crop: ratio, fill, snapping; resize: output size; rotate and flip); Cancel or
/// Apply at the bottom.
private struct CropPanel: View {
    @Bindable var state: CropState
    let doc: AnnotationDocument
    let imageFill: (CropState.Fill) -> CGColor?
    let actions: AnnotateSidebarActions

    private static let fills: [CropState.Fill] = [.transparent, .auto, .white, .gray, .black]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PanelTitle(title: "Crop & Resize", subtitle: "Crop picks the part to keep, Resize sets how many pixels the result has. Both apply together.")

                    CropSection(title: "Crop", subtitle: "Drag the frame or its handles. Drag it past the screenshot to add room around it.", first: true)
                    InspectorHeader("Aspect ratio")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        // Custom last; picking it opens its line below.
                        ForEach(CropState.Ratio.allCases.filter { $0 != .customRatio } + [.customRatio]) { ratio in
                            TileButton(selected: state.ratio == ratio, height: 28, help: ratio == .customRatio ? "Type your own ratio" : SocialRatio.hint(ratio.title).map { "\(ratio.title): \($0)" } ?? ratio.title) {
                                actions.setCropRatio(ratio)
                            } label: {
                                Text(ratio == .customRatio ? "Custom" : ratio.title).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                            }
                        }
                    }
                    if state.ratio == .customRatio {
                        HStack(spacing: 8) {
                            Text("Custom ratio").font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
                            Spacer()
                            HStack(spacing: 0) {
                                CropRatioField(state: state, width: true)
                                Text(verbatim: ":").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.55))
                                CropRatioField(state: state, width: false)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box))
                            .help("Aspect ratio, e.g. 16 : 9 (Return or a click elsewhere applies it; the side you edit changes)")
                        }
                        .transition(.opacity)
                    }

                    InspectorHeader("Fill around the screenshot").padding(.top, 6)
                    HStack(spacing: 8) {
                        ForEach(Self.fills, id: \.title) { fill in
                            fillDot(fill)
                        }
                        Button(action: actions.customCropFill) {
                            Image(nsImage: SwatchImage.colorWheel(diameter: 22)).resizable().frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(isCustom ? Color.white : .clear, lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help("Custom color…")
                    }

                    Toggle(isOn: $state.snapToEdges) {
                        Text("Snap to edges").font(.system(size: 13.5)).foregroundStyle(.white)
                    }
                    .toggleStyle(BlueSwitch())
                    .padding(.top, 6)
                    Text("Hold ⌘ while dragging to stop snapping for a moment.").font(.system(size: 12)).foregroundStyle(Color(white: 0.55))

                    CropSection(title: "Resize", subtitle: "The result's size. Lower it for a smaller file, e.g. 50% to turn a Retina screenshot into standard size.")
                    InspectorHeader("Image size")
                    imageSize

                    CropSection(title: "Rotate & Flip", subtitle: "Turns or mirrors the screenshot right away; annotations go along.")
                    HStack(spacing: 6) {
                        TileButton(selected: false, height: 32, help: "Rotate 90°", action: actions.rotate) {
                            Label("Rotate", systemImage: "rotate.right").font(.system(size: 12.5, weight: .medium))
                        }
                        TileButton(selected: doc.isFlipped, height: 32, help: doc.isFlipped ? "Flipped: flip back" : "Flip horizontally", action: actions.flip) {
                            Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right").font(.system(size: 12.5, weight: .medium))
                        }
                    }
                }
                .padding(EdgeInsets(top: 22, leading: 22, bottom: 16, trailing: 22))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            Rectangle().fill(W.line).frame(height: 1)
            HStack(spacing: 8) {
                TileButton(selected: false, height: 32, help: "Leave Crop & Resize without changes (Esc)", action: actions.cancelCrop) {
                    Text("Cancel").font(.system(size: 13.5, weight: .medium))
                }
                TileButton(selected: true, height: 32, help: "Apply the crop and size (Return)", action: actions.applyCrop) {
                    Text("Apply").font(.system(size: 13.5, weight: .semibold))
                }
            }
            .padding(14)
        }
    }

    private var isCustom: Bool { if case .custom = state.fill { true } else { false } }

    private func fillDot(_ fill: CropState.Fill) -> some View {
        let selected = state.fill == fill
        return Button { actions.setCropFill(fill) } label: {
            Group {
                if let color = imageFill(fill), let ns = NSColor(cgColor: color) {
                    Circle().fill(Color(nsColor: ns))
                } else {
                    Image(nsImage: SwatchImage.transparentCircle(diameter: 22)).resizable()
                }
            }
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            .overlay(alignment: .bottomTrailing) {
                if fill == .auto { Text("A").font(.system(size: 8, weight: .bold)).foregroundStyle(.white).padding(2).background(Circle().fill(Color.black.opacity(0.6))) }
            }
            .overlay(Circle().strokeBorder(selected ? Color.white : .clear, lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
        .help(fill == .auto ? "Auto: the screenshot's edge color" : fill.title)
    }

    /// Width and height of the result, a lock that keeps their ratio, pixels or percent.
    private var imageSize: some View {
        HStack(spacing: 6) {
            sizeField(width: true)
            Button { state.lockOutputRatio.toggle() } label: {
                Image(systemName: state.lockOutputRatio ? "lock.fill" : "lock.open").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(state.lockOutputRatio ? W.blue : W.box))
            }
            .buttonStyle(.plain)
            .help(state.lockOutputRatio ? "Unlock the ratio" : "Lock the ratio")
            sizeField(width: false)
            HStack(spacing: 2) {
                ForEach([("px", false), ("%", true)], id: \.1) { title, percent in
                    Button { state.outputInPercent = percent } label: {
                        Text(title).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(state.outputInPercent == percent ? Color.white : Color(white: 0.55))
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(state.outputInPercent == percent ? W.blue : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box))
        }
    }

    private func sizeField(width: Bool) -> some View {
        let px = state.outputPixels
        let value = state.outputInPercent ? ((width ? state.outputScaleX : state.outputScaleY) * 100).rounded() : (width ? px.width : px.height)
        return HStack(spacing: 2) {
            Text(width ? "W" : "H").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(white: 0.55))
            CropDraftField(current: CropNumber.text(value), width: 38) { text in
                guard let v = CropNumber.parse(text), v > 0 else { return }
                state.setOutput(v, width: width)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box))
    }
}
