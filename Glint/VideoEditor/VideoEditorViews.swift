import AppKit
import AVFoundation
import SwiftUI

struct VideoEditorActions {
    var togglePlay: () -> Void
    var seek: (Double) -> Void
    var toStart: () -> Void
    var toEnd: () -> Void
    var frame: (Double) -> CGImage?
    var toggleFullScreen: () -> Void
}

private typealias W = VideoEditorWindowController

/// The editor below the title bar: 49pt rail | 272pt inspector | preview over a 50pt
/// transport bar, and the 258pt timeline across the bottom.
struct VideoEditorContent: View {
    @ObservedObject var project: VideoProject
    @ObservedObject var state: VideoEditorState
    let player: AVPlayer
    let timeline: VideoTimelineView
    let actions: VideoEditorActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VideoRail(state: state)
                    .frame(width: 49)
                Rectangle().fill(W.line).frame(width: 1)
                VideoInspector(project: project, state: state, actions: actions)
                    .frame(width: 272)
                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        PlayerSurface(player: player, project: project)
                            .padding(EdgeInsets(top: 30, leading: 30, bottom: 30, trailing: 30))
                        Button(action: actions.toggleFullScreen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.6)).frame(width: 24, height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Full screen preview").padding(10)
                    }
                    .background(W.dark)
                    VideoTransport(project: project, state: state, actions: actions)
                        .frame(height: 50)
                }
            }
            TimelineHost(timeline: timeline)
                .frame(height: 258)
        }
        .background(W.base)
        .environment(\.colorScheme, .dark)
    }
}

/// The preview: the player (video + zooms) inside a layer-built canvas: backdrop, padding, rounded corners and
/// shadow are CALayers, so the Background sliders apply instantly and to the whole video, without re-rendering
/// frames. The export renders the same look into the file (`VideoFrameRenderer`).
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    @ObservedObject var project: VideoProject
    func makeNSView(context: Context) -> PreviewCanvasView { PreviewCanvasView(player: player) }
    func updateNSView(_ view: PreviewCanvasView, context: Context) {
        view.update(background: project.background, sourceSize: project.sourceSize, backdrop: { project.previewBackdrop() })
    }
}

final class PreviewCanvasView: NSView {
    private let backdrop = CALayer()
    private let shadowLayer = CALayer()
    /// The wide one of the two shadow layers (`BackgroundShadow`).
    private let wideShadowLayer = CALayer()
    private let card = CALayer()
    private let playerLayer = AVPlayerLayer()
    private var background = VideoBackground()
    private var sourceSize = CGSize(width: 16, height: 9)
    private var backdropFill: Glint.BackgroundStyle.Fill?

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.masksToBounds = true
        backdrop.cornerRadius = 10
        backdrop.cornerCurve = .continuous
        shadowLayer.shadowColor = NSColor.black.cgColor
        wideShadowLayer.shadowColor = NSColor.black.cgColor
        card.masksToBounds = true
        card.cornerCurve = .continuous
        playerLayer.player = player
        playerLayer.videoGravity = .resize
        card.addSublayer(playerLayer)
        layer?.addSublayer(backdrop)
        layer?.addSublayer(wideShadowLayer)
        layer?.addSublayer(shadowLayer)
        layer?.addSublayer(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(background: VideoBackground, sourceSize: CGSize, backdrop image: () -> CGImage?) {
        guard background != self.background || sourceSize != self.sourceSize || backdropFill == nil else { return }
        self.background = background
        self.sourceSize = sourceSize
        if background.isVisible, backdropFill != background.fill {
            backdropFill = background.fill
            backdrop.contents = image()
        }
        if backdropFill == nil { backdropFill = background.fill }
        layoutLayers()
    }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        guard sourceSize.width > 0, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let canvas = VideoFrameRenderer.canvas(for: sourceSize, background: background)
        let k = min(bounds.width / canvas.size.width, bounds.height / canvas.size.height)
        let fit = CGRect(x: (bounds.width - canvas.size.width * k) / 2, y: (bounds.height - canvas.size.height * k) / 2,
                         width: canvas.size.width * k, height: canvas.size.height * k)
        let visible = background.isVisible
        backdrop.isHidden = !visible
        backdrop.frame = fit
        // The canvas (y-up, like the layers here) scaled into the view.
        let cardRect = visible
            ? CGRect(x: fit.minX + canvas.card.minX * k, y: fit.minY + canvas.card.minY * k, width: canvas.card.width * k, height: canvas.card.height * k)
            : fit
        let radius = visible ? background.corners * VideoBackground.maxCornerFraction * min(canvas.card.width, canvas.card.height) * k : 10
        card.frame = cardRect
        card.cornerRadius = min(radius, min(cardRect.width, cardRect.height) / 2)
        playerLayer.frame = card.bounds
        // Same shadow as the export.
        let layers = visible ? BackgroundShadow.layers(background.shadow) : []
        let scale = min(canvas.card.width, canvas.card.height) / BackgroundShadow.measuredShortSide * k
        for (i, shadow) in [shadowLayer, wideShadowLayer].enumerated() {
            shadow.isHidden = i >= layers.count
            guard i < layers.count else { continue }
            shadow.frame = cardRect
            shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: cardRect.size), cornerWidth: card.cornerRadius,
                                       cornerHeight: card.cornerRadius, transform: nil)
            shadow.shadowRadius = layers[i].sigma * scale
            shadow.shadowOffset = CGSize(width: 0, height: -layers[i].offset * scale)
            shadow.shadowOpacity = Float(layers[i].opacity)
        }
        CATransaction.commit()
    }
}

private struct TimelineHost: NSViewRepresentable {
    let timeline: VideoTimelineView
    func makeNSView(context: Context) -> NSView { timeline.scrollView }
    func updateNSView(_ view: NSView, context: Context) {}
}

// MARK: - Rail

/// Section icons (18pt, gray); the selected one sits on a 30pt blue rounded square. The scissors at the bottom
/// toggle the cut tool.
private struct VideoRail: View {
    @ObservedObject var state: VideoEditorState

    var body: some View {
        VStack(spacing: 20) {
            ForEach(VideoEditorState.Section.allCases, id: \.self) { section in
                railButton(selected: state.section == section && state.selectedZoom == nil, title: section.title, help: section.title) {
                    section.icon
                } action: {
                    state.selectedZoom = nil
                    state.section = section
                }
            }
            Spacer()
            railButton(selected: state.scissors, title: "Cut", help: "Cut (C): click the clip to split it, drag across it to cut that part out") {
                Image(systemName: "scissors").font(.system(size: 15, weight: .medium))
            } action: { state.scissors.toggle() }
            .padding(.bottom, 14)
        }
        .padding(.top, 10)
    }

    private func railButton(selected: Bool, title: String, help: String, @ViewBuilder icon: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            icon()
                .foregroundStyle(selected ? Color.white : Color(white: 0.55))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? W.blue : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }
}

extension VideoEditorState.Section {
    var title: String {
        switch self {
        case .cursor: "Cursor"
        case .keystrokes: "Keystrokes"
        case .audio: "Audio"
        case .camera: "Camera"
        case .background: "Background"
        case .animation: "Animation"
        }
    }

    @ViewBuilder var icon: some View {
        switch self {
        case .cursor: Image(systemName: "cursorarrow.rays").font(.system(size: 15, weight: .medium))
        case .keystrokes: Image(systemName: "command.square.fill").font(.system(size: 17))
        case .audio: Image(systemName: "speaker.wave.2.fill").font(.system(size: 14))
        case .camera: Image(systemName: "video.fill").font(.system(size: 14))
        case .background: Image(systemName: "photo.fill").font(.system(size: 15))
        case .animation: MotionGlyph().frame(width: 20, height: 14)
        }
    }
}

/// The motion icon: a filled circle with two speed arcs on its left.
private struct MotionGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let r = size.height / 2
            let c = CGPoint(x: size.width - r, y: r)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: 0, width: r * 2, height: r * 2)), with: .foreground)
            for (offset, width) in [(4.0, 1.6), (7.5, 1.3)] {
                var arc = Path()
                arc.addArc(center: CGPoint(x: c.x - offset, y: c.y), radius: r * 0.9, startAngle: .degrees(140), endAngle: .degrees(220), clockwise: false)
                ctx.stroke(arc, with: .foreground, style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
        }
    }
}

// MARK: - Inspector

private struct VideoInspector: View {
    @ObservedObject var project: VideoProject
    @ObservedObject var state: VideoEditorState
    let actions: VideoEditorActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let id = state.selectedZoom, let zoom = project.zooms.first(where: { $0.id == id }) {
                    ZoomInspector(project: project, state: state, zoom: zoom, actions: actions)
                } else {
                    switch state.section {
                    case .cursor:
                        if project.isStudio { CursorInspector(project: project) }
                        else { studioOnly("Cursor", "Cursor settings are only available for videos recorded in Studio Mode. In this recording the cursor is part of the video.") }
                    case .keystrokes:
                        if project.isStudio { KeystrokesInspector(project: project) }
                        else { studioOnly("Keystrokes", "Keystroke settings are only available for videos recorded in Studio Mode. In this recording, shown keystrokes are part of the video.") }
                    case .camera:
                        if project.isStudio { CameraInspector(project: project) }
                        else { studioOnly("Camera", "Camera settings are only available for videos recorded in Studio Mode. In this recording the camera is part of the video.") }
                    case .audio: AudioInspector(project: project)
                    case .background: VideoBackgroundInspector(project: project)
                    case .animation: AnimationInspector(project: project)
                    }
                }
            }
            .padding(EdgeInsets(top: 26, leading: 25, bottom: 20, trailing: 25))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func studioOnly(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader(title)
            InfoBox { Text(text) }
        }
    }
}

struct InspectorHeader: View {
    let title: String
    var value: String?
    init(_ title: String, value: String? = nil) { self.title = title; self.value = value }
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
            Spacer()
            if let value { Text(value).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white) }
        }
    }
}

/// A rounded #2A2A2A box with light text.
struct InfoBox<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        // The notice: gray 14pt text in a #2A2A2A box with 16pt corners.
        HStack(spacing: 10) { content }
            .font(.system(size: 14))
            .foregroundStyle(Color(white: 0.6))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 15, leading: 15, bottom: 15, trailing: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(W.box))
    }
}

/// The switch: blue when on, also while the window is inactive (the system switch turns gray then).
struct BlueSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(configuration.isOn ? W.blue : Color.white.opacity(0.15))
                .frame(width: 32, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(Color(white: 0.92)).frame(width: 20, height: 14).padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
            configuration.label
        }
    }
}

/// Two-choice segmented buttons (blue = selected), 30pt tall.
struct ChoiceButtons: View {
    let titles: [String]
    let selected: Int
    var disabled: Set<Int> = []
    var helps: [String] = []
    let pick: (Int) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach(titles.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Text(titles[i]).font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(disabled.contains(i) ? Color(white: 0.4) : .white)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(i == selected ? W.blue : W.box))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled.contains(i))
                .help(i < helps.count ? helps[i] : "")
            }
        }
    }
}

/// The inspector slider: a 6pt track, blue up to the knob and dark gray after it, a light
/// 20×15pt rounded knob, and small dots under the track (the ends, or each snap step).
struct StepSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var ticks: Int = 5
    @Environment(\.isEnabled) private var enabled
    private let knob = CGSize(width: 20, height: 15)

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - knob.width
            let f = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let kx = usable * min(max(f, 0), 1)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.white.opacity(0.1)).frame(height: 6).offset(y: (knob.height - 6) / 2)
                Capsule().fill(W.blue).frame(width: kx + knob.width / 2, height: 6).offset(y: (knob.height - 6) / 2)
                ForEach(0..<ticks, id: \.self) { i in
                    Circle().fill(Color(white: 0.4)).frame(width: 2.5, height: 2.5)
                        .offset(x: knob.width / 2 - 1.25 + usable * CGFloat(i) / CGFloat(max(ticks - 1, 1)), y: knob.height + 4)
                }
                RoundedRectangle(cornerRadius: 7.5, style: .continuous).fill(Color(white: 0.9))
                    .frame(width: knob.width, height: knob.height)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .offset(x: kx)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let p = Double(min(max((g.location.x - knob.width / 2) / max(usable, 1), 0), 1))
                var v = range.lowerBound + p * (range.upperBound - range.lowerBound)
                if let step { v = (v / step).rounded() * step }
                value = min(max(v, range.lowerBound), range.upperBound)
            })
        }
        .frame(height: knob.height + 8)
        .opacity(enabled ? 1 : 0.5)
    }
}

private struct AudioInspector: View {
    @ObservedObject var project: VideoProject
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Audio")
            if project.hasAudio {
                // The switch first, then the volume in a box (0–200%, 100% in the middle).
                Toggle(isOn: $project.edit.includeAudio) { Text("Include audio").font(.system(size: 13.5)).foregroundStyle(.white) }
                    .toggleStyle(BlueSwitch())
                    .help("Play and export the video with its sound")
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 12)).foregroundStyle(.white)
                        Text("Volume").font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
                        Spacer()
                        Text("\(Int((project.volume * 100).rounded()))%").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    }
                    StepSlider(value: $project.edit.volume, range: 0...2, ticks: 2)
                        .help("Volume of the video's sound (100% = as recorded)")
                }
                .padding(EdgeInsets(top: 13, leading: 15, bottom: 10, trailing: 15))
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(W.box))
                .opacity(project.includeAudio ? 1 : 0.45)
                .disabled(!project.includeAudio)
            } else {
                InfoBox { Text("Audio recording was disabled for this recording.") }
            }
        }
    }
}

private struct AnimationInspector: View {
    @ObservedObject var project: VideoProject
    private static let blurNames = ["Off", "Low", "Medium", "High"]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Motion Blur", value: Self.blurNames[project.motionBlur])
            StepSlider(value: Binding(get: { Double(project.motionBlur) }, set: { project.motionBlur = Int($0.rounded()) }),
                       range: 0...3, step: 1, ticks: 4)
                .help("How much the picture blurs while a zoom moves")
            InspectorHeader("Zoom animations").padding(.top, 16)
            ChoiceButtons(titles: ["Smooth", "Dynamic"], selected: project.zoomAnimation == .smooth ? 0 : 1,
                          helps: ["Zooms glide in and out evenly", "Zooms start and stop quickly, with a faster middle"]) {
                project.zoomAnimation = $0 == 0 ? .smooth : .dynamic
            }
        }
    }
}

/// A selected zoom: its level, "Apply Zoom Level to All", the mode and a mini preview to place the focus.
private struct ZoomInspector: View {
    @ObservedObject var project: VideoProject
    @ObservedObject var state: VideoEditorState
    /// A snapshot; edits go back by id (the zoom may be removed while this view updates).
    let zoom: VideoZoom
    let actions: VideoEditorActions

    private func edit(_ change: (inout VideoZoom) -> Void) {
        guard let i = project.zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
        change(&project.zooms[i])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Zoom level", value: "\(Int((zoom.scale * 100).rounded()))%")
            StepSlider(value: Binding(get: { zoom.scale }, set: { v in edit { $0.scale = v } }),
                       range: 1.0...4.0, step: 0.05, ticks: 7)
                .help("How far this zoom magnifies (100–400%)")
            Button { let s = zoom.scale; for i in project.zooms.indices { project.zooms[i].scale = s } } label: {
                Text("Apply Zoom Level to All").font(.system(size: 13.5, weight: .medium)).frame(maxWidth: .infinity).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Give every zoom this zoom level")
            InspectorHeader("Zoom mode").padding(.top, 14)
            // Following the cursor needs the pointer positions a Studio Mode recording keeps.
            ChoiceButtons(titles: ["Follow Cursor", "Manual"], selected: zoom.follow && project.isStudio ? 0 : 1,
                          disabled: project.isStudio ? [] : [0],
                          helps: [project.isStudio ? "The zoom keeps the cursor in view and pans with it" : "Follow Cursor needs a video recorded in Studio Mode",
                                  "Zoom into the spot you pick below"]) { i in edit { $0.follow = i == 0 } }
            if zoom.follow && project.isStudio {
                InfoBox { Text("The zoom follows the cursor and pans when the cursor comes close to its edge.") }
                    .padding(.top, 4)
            } else {
                ZoomFocusPicker(zoom: zoom, project: project) { center in
                    edit { $0.center = center }
                }
                .padding(.top, 4)
                .help("Drag the dot to choose where the zoom looks")
            }
            InspectorHeader("Animation").padding(.top, 14)
            Button {
                state.selectedZoom = nil
                state.section = .animation
            } label: {
                Text("Animation Settings").font(.system(size: 13.5, weight: .medium)).frame(maxWidth: .infinity).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Motion blur and zoom easing for all zooms")
        }
    }
}

/// The frame (sharp, from the video itself) with the zoomed area outlined and the rest dimmed; drag the dot (or
/// click) to move the focus. Near the middle the focus snaps onto the vertical/horizontal center line, shown in red.
private struct ZoomFocusPicker: View {
    let zoom: VideoZoom
    let project: VideoProject
    let move: (CGPoint) -> Void
    @State private var image: CGImage?
    @State private var snapX = false
    @State private var snapY = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let size = fitted(in: geo.size)
            let origin = CGPoint(x: (geo.size.width - size.width) / 2, y: (geo.size.height - size.height) / 2)
            let box = CGSize(width: size.width / zoom.scale, height: size.height / zoom.scale)
            // The zoomed area: centered on the focus point, kept inside the frame per axis (same as the renderer).
            let target = VideoFrameRenderer.zoomTarget(zoom)
            let bx = target.minX * size.width, by = target.minY * size.height
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                } else {
                    Rectangle().fill(Color.black).frame(width: size.width, height: size.height)
                }
                // Dim outside the zoomed area.
                Rectangle().fill(Color.black.opacity(0.45))
                    .mask(ZStack(alignment: .topLeading) {
                        Rectangle()
                        Rectangle().frame(width: box.width, height: box.height).offset(x: bx, y: by).blendMode(.destinationOut)
                    }.compositingGroup())
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: box.width, height: box.height).offset(x: bx, y: by)
                if dragging && snapX { Rectangle().fill(Color.red).frame(width: 1, height: size.height).offset(x: size.width / 2 - 0.5) }
                if dragging && snapY { Rectangle().fill(Color.red).frame(width: size.width, height: 1).offset(y: size.height / 2 - 0.5) }
                Circle().fill(Color.white).frame(width: 16, height: 16).shadow(radius: 2)
                    .offset(x: zoom.center.x * size.width - 8, y: zoom.center.y * size.height - 8)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .offset(x: origin.x, y: origin.y)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                dragging = true
                var p = CGPoint(x: (g.location.x - origin.x) / size.width, y: (g.location.y - origin.y) / size.height)
                p = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
                // Snap within 6pt of the center lines.
                snapX = abs(p.x - 0.5) * size.width < 6
                snapY = abs(p.y - 0.5) * size.height < 6
                if snapX { p.x = 0.5 }
                if snapY { p.y = 0.5 }
                move(p)
            }.onEnded { _ in dragging = false })
        }
        .frame(height: 160)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(W.box))
        .task(id: zoom.id) { image = await project.still(at: (zoom.start + zoom.end) / 2, maxSize: CGSize(width: 900, height: 600)) }
    }

    private func fitted(in box: CGSize) -> CGSize {
        let source = project.sourceSize
        guard source.width > 0 else { return box }
        let scale = min(box.width / source.width, box.height / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

/// The Background section: None, gradients, wallpapers, plain colors, aspect ratio, padding, shadow, corners.
private struct VideoBackgroundInspector: View {
    @ObservedObject var project: VideoProject
    @State private var showAllGradients = false
    @State private var wallpaperReady = BackgroundImages.shared.wallpaper != nil
    private var bg: VideoBackground { project.background }
    private let grid = Array(repeating: GridItem(.fixed(38), spacing: 10), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Background")
            Button { project.background.padding = 0; project.background.ratio = .auto } label: {
                Text("None").font(.system(size: 13.5, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(W.box))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(bg.isVisible ? .clear : W.blue, lineWidth: 2.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("No background around the video")
            HStack {
                InspectorHeader("Gradients")
                Button { showAllGradients.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(showAllGradients ? "Show less" : "Show more")
                        Image(systemName: showAllGradients ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12.5)).foregroundStyle(Color(white: 0.62))
                }
                .buttonStyle(.plain)
                .help(showAllGradients ? "Show fewer gradients" : "Show all gradients")
            }
            .padding(.top, 8)
            LazyVGrid(columns: grid, alignment: .leading, spacing: 10) {
                ForEach(0..<(showAllGradients ? BackgroundPalette.count : 10), id: \.self) { i in
                    swatch(selected: bg.isVisible && bg.fill == .gradient(i)) { Image(nsImage: BackgroundPalette.swatch(i)).resizable() } pick: { choose(.gradient(i)) }
                        .help("Gradient background")
                }
            }
            InspectorHeader("Wallpapers").padding(.top, 8)
            HStack(spacing: 10) {
                swatch(selected: bg.isVisible && bg.fill == .wallpaper) {
                    if wallpaperReady, let wp = BackgroundImages.shared.wallpaper { Image(decorative: wp, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                    else { Color.gray }
                } pick: { choose(.wallpaper) }
                .help("Your desktop wallpaper as the background")
                if case .customImage(let path) = bg.fill, let image = NSImage(contentsOfFile: path) {
                    swatch(selected: true) { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } pick: {}
                        .help("Your image (in use)")
                }
                Button(action: pickImage) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(white: 0.8))
                        .frame(width: 38, height: 38)
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Color(white: 0.45)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Choose your own image as the background")
            }
            InspectorHeader("Plain color").padding(.top, 8)
            ForEach([BackgroundPalette.colorsDark, BackgroundPalette.colorsLight], id: \.self) { row in
                HStack(spacing: 9) {
                    ForEach(row, id: \.self) { hex in
                        Button { choose(.color(hex)) } label: {
                            Circle().fill(Color(nsColor: BackgroundPalette.nsColor(hex))).frame(width: 19, height: 19)
                                .overlay(Circle().strokeBorder(bg.isVisible && bg.fill == .color(hex) ? W.blue : .clear, lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain)
                        .help("Plain color background")
                    }
                }
            }
            Divider().overlay(W.line).padding(.vertical, 10)
            InspectorHeader("Aspect Ratio")
            Picker("", selection: $project.edit.background.ratio) {
                ForEach([BackgroundStyle.Ratio.auto, .square, .r4x3, .r3x2, .r16x9, .r16x10, .r9x16], id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .help("Shape of the exported video (Auto keeps the video's own)")
            InspectorHeader("Padding", value: "\(Int((bg.padding * 100).rounded()))%").padding(.top, 10)
            StepSlider(value: $project.edit.background.padding, range: 0...1, ticks: 7)
                .help("Space between the video and the edge of the background")
            InspectorHeader("Shadow", value: "\(Int((bg.shadow * 100).rounded()))").padding(.top, 10)
            StepSlider(value: $project.edit.background.shadow, range: 0...1, ticks: 7).disabled(!bg.isVisible)
                .help(bg.isVisible ? "Shadow under the video" : "Needs a background (add padding or pick one)")
            InspectorHeader("Corner radius", value: "\(Int((bg.corners * 100).rounded()))").padding(.top, 10)
            StepSlider(value: $project.edit.background.corners, range: 0...1, ticks: 7).disabled(!bg.isVisible)
                .help(bg.isVisible ? "Rounds the video's corners" : "Needs a background (add padding or pick one)")
        }
        .task {
            await BackgroundImages.shared.prepare()
            wallpaperReady = BackgroundImages.shared.wallpaper != nil
        }
    }

    private func swatch(selected: Bool, @ViewBuilder content: () -> some View, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            content().frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? W.blue : .clear, lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
    }

    /// Picking a fill shows the background: without padding there'd be nothing to see.
    private func choose(_ fill: BackgroundStyle.Fill) {
        project.background.fill = fill
        if !project.background.isVisible { project.background.padding = 0.3 }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { choose(.customImage(url.path)) }
    }
}

// MARK: - Transport

/// "00:00 / 00:05" on the left, back / play / forward in the middle, the timeline zoom slider on the right.
private struct VideoTransport: View {
    @ObservedObject var project: VideoProject
    @ObservedObject var state: VideoEditorState
    let actions: VideoEditorActions

    var body: some View {
        ZStack {
            HStack(spacing: 5) {
                Text(Self.format(state.time)).foregroundStyle(.white)
                Text("/").foregroundStyle(Color(white: 0.55))
                Text(Self.format(project.duration)).foregroundStyle(Color(white: 0.55))
                    .help("Playhead position / length of the edited video")
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.45))
                    Slider(value: $state.timelineZoom, in: 0...1) { state.timelineZoomEditing = $0 }.controlSize(.mini).frame(width: 100).tint(Color(white: 0.4))
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(white: 0.45))
                }
                .help("Zoom the timeline in or out (⌘+ / ⌘−)")
            }
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            HStack(spacing: 34) {
                transportButton("backward.end.fill", help: "Go to start", action: actions.toStart)
                transportButton(state.isPlaying ? "pause.fill" : "play.fill", help: state.isPlaying ? "Pause" : "Play", size: 19, action: actions.togglePlay)
                transportButton("forward.end.fill", help: "Go to end", action: actions.toEnd)
            }
        }
        .padding(.horizontal, 20)
    }

    private func transportButton(_ symbol: String, help: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(.white).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        // The symbols' built-in names read "Go To End" for backward.end and vice versa.
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    static func format(_ t: Double) -> String {
        let s = Int(max(t, 0).rounded(.down))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
