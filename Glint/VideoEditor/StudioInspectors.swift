import AppKit
import SwiftUI

private typealias W = VideoEditorWindowController

/// The Cursor section (Studio Mode): show, size, style, movement, press and ripple effects, hiding.
struct CursorInspector: View {
    @ObservedObject var project: VideoProject
    private var cursor: CursorSettings { project.edit.cursor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Cursor")
            MainSwitch(title: "Show cursor", isOn: $project.edit.cursor.show, help: "Draw the cursor in the video")
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader("Size", percent: $project.edit.cursor.size, range: 0.5...3).padding(.top, 8)
                StepSlider(value: $project.edit.cursor.size, range: 0.5...3, ticks: 6)
                    .help("How big the cursor is (100% = as it was on screen)")
                InspectorHeader("Style").padding(.top, 8)
                HStack(spacing: 8) {
                    ForEach(CursorStyle.allCases, id: \.self) { style in
                        StyleTile(title: style.title, selected: cursor.style == style, help: Self.help(style)) {
                            CursorPreview(style: style, project: project)
                        } pick: { project.edit.cursor.style = style }
                    }
                }
                InspectorHeader("Movement").padding(.top, 8)
                ChoiceButtons(titles: ["Natural", "Smooth"], selected: cursor.movement == .natural ? 0 : 1,
                              helps: ["The cursor moves as it did while recording, without jitter", "The cursor glides calmly from place to place"]) {
                    project.edit.cursor.movement = $0 == 0 ? .natural : .smooth
                }
                Divider().overlay(W.line).padding(.vertical, 6)
                Check(title: "Press animation", isOn: $project.edit.cursor.pressEffect, help: "The cursor shrinks a little while a button is held")
                Check(title: "Ripple animation", isOn: $project.edit.cursor.ripple.animation(.easeOut(duration: 0.15)),
                      help: "A ring spreads out from every click")
                if cursor.ripple { rippleOptions.transition(.opacity) }
                Check(title: "Hide cursor when not moving", isOn: $project.edit.cursor.hideWhenIdle,
                      help: "The cursor fades out after 1.5 s without moving and comes back when it moves")
                Check(title: "Hide cursor when typing", isOn: $project.edit.cursor.hideWhenTyping,
                      help: "The cursor hides from the first key press until the mouse moves again")
            }
            .disabled(!cursor.show)
            .opacity(cursor.show ? 1 : 0.45)
        }
    }

    private static func help(_ style: CursorStyle) -> String {
        switch style {
        case .system: "The cursors exactly as they looked while recording"
        case .bold: "A black arrow with a white outline"
        case .light: "A white arrow with a dark outline"
        case .touch: "A soft dot, like a finger on a touch screen"
        }
    }

    /// Color dots and Outline / Filled, in a box under the checkbox.
    private var rippleOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Color", value: cursor.rippleColor.title)
            HStack(spacing: 9) {
                ForEach(RippleColor.allCases, id: \.self) { color in
                    Button { project.edit.cursor.rippleColor = color } label: {
                        Circle().fill(Color(nsColor: color.color)).frame(width: 19, height: 19)
                            .overlay(Circle().strokeBorder(cursor.rippleColor == color ? W.blue : .clear, lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(color.title)
                }
            }
            InspectorHeader("Style").padding(.top, 4)
            ChoiceButtons(titles: ["Outline", "Filled"], selected: cursor.rippleFilled ? 1 : 0,
                          helps: ["A ring", "A filled circle"]) { project.edit.cursor.rippleFilled = $0 == 1 }
        }
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(W.box))
    }
}

/// The Keystrokes section (Studio Mode): show, size, dark / light, position, which keys.
struct KeystrokesInspector: View {
    @ObservedObject var project: VideoProject
    private var keys: KeystrokeSettings { project.edit.keystrokes }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Keystrokes")
            if let studio = project.studio, !studio.keysRecorded {
                InfoBox { Text("Keystrokes weren't recorded: Glint needs the Input Monitoring permission (System Settings → Privacy & Security).") }
            } else if project.studio?.keys.isEmpty ?? true {
                InfoBox { Text("No keystrokes were captured in this video.") }
            } else {
                MainSwitch(title: "Show keystrokes", isOn: $project.edit.keystrokes.show, help: "Show the keys you pressed in the video")
                VStack(alignment: .leading, spacing: 10) {
                    InspectorHeader("Size", percent: $project.edit.keystrokes.size, range: 0.5...2).padding(.top, 8)
                    StepSlider(value: $project.edit.keystrokes.size, range: 0.5...2, ticks: 7)
                        .help("How big the keystroke labels are")
                    InspectorHeader("Style").padding(.top, 8)
                    ChoiceButtons(titles: ["Dark", "Light"], selected: keys.light ? 1 : 0,
                                  helps: ["White keys on a dark label", "Dark keys on a light label"]) { project.edit.keystrokes.light = $0 == 1 }
                    InspectorHeader("Position", value: keys.position.title).padding(.top, 8)
                    PositionPicker(options: [.topLeft, .topRight, .bottomLeft, .bottom, .bottomRight], selected: keys.position,
                                   spot: CGSize(width: 38, height: 13)) { project.edit.keystrokes.position = $0 }
                    InspectorHeader("Show").padding(.top, 8)
                    ChoiceButtons(titles: ["All Keys", "Shortcuts"], selected: keys.allKeys ? 0 : 1,
                                  helps: ["Everything you type, shortcuts included", "Only shortcuts with ⌘, ⌥ or ⌃"]) {
                        project.edit.keystrokes.allKeys = $0 == 0
                    }
                }
                .disabled(!keys.show)
                .opacity(keys.show ? 1 : 0.45)
            }
        }
    }
}

/// The Camera section (Studio Mode): show, size, shape, corner, mirror, shrink while zoomed.
struct CameraInspector: View {
    @ObservedObject var project: VideoProject
    private var camera: CameraSettings { project.edit.camera }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorHeader("Camera")
            if !project.hasCamera {
                InfoBox { Text("Camera recording was disabled for this recording.") }
            } else {
                MainSwitch(title: "Show camera", isOn: $project.edit.camera.show, help: "Show the camera in the video")
                VStack(alignment: .leading, spacing: 10) {
                    InspectorHeader("Size", percent: $project.edit.camera.size, range: 0.5...2).padding(.top, 8)
                    StepSlider(value: $project.edit.camera.size, range: 0.5...2, ticks: 7)
                        .help("How big the camera is (100% = the recorder's Medium)")
                    InspectorHeader("Shape").padding(.top, 8)
                    CameraShapePicker(selected: camera.shape) { project.edit.camera.shape = $0 }
                    InspectorHeader("Position", value: camera.position.title).padding(.top, 8)
                    PositionPicker(options: [.topLeft, .topRight, .bottomLeft, .bottomRight], selected: camera.position,
                                   spot: CGSize(width: 18, height: 18), round: camera.shape == 0) { project.edit.camera.position = $0 }
                    Divider().overlay(W.line).padding(.vertical, 6)
                    Check(title: "Flip camera", isOn: $project.edit.camera.flip, help: "Mirror the camera picture, like a mirror")
                    Check(title: "Shrink camera on zoom", isOn: $project.edit.camera.shrinkOnZoom,
                          help: "The camera gets smaller while the video is zoomed in")
                }
                .disabled(!camera.show)
                .opacity(camera.show ? 1 : 0.45)
            }
        }
    }
}

/// A selected camera layout (Studio Mode): full size, a bubble of its own (size, shape, corner) or hidden.
struct CameraLayoutInspector: View {
    @ObservedObject var project: VideoProject
    @ObservedObject var state: VideoEditorState
    /// A snapshot; edits go back by id (the layout may be removed while this view updates).
    let layout: CameraLayout

    private func edit(_ change: (inout CameraLayout) -> Void) {
        guard let i = project.cameraLayouts.firstIndex(where: { $0.id == layout.id }) else { return }
        change(&project.cameraLayouts[i])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let kinds = CameraLayout.Kind.allCases
            InspectorHeader("Camera layout", value: String(format: "%.1f s", layout.end - layout.start))
            ChoiceButtons(titles: kinds.map(\.title), selected: kinds.firstIndex(of: layout.kind) ?? 0,
                          helps: ["The camera fills the whole video", "The camera as a bubble with its own size, shape and corner",
                                  "No camera here"]) { i in edit { $0.kind = kinds[i] } }
            if layout.kind == .bubble {
                let size = Binding(get: { layout.size }, set: { v in edit { $0.size = v } })
                InspectorHeader("Size", percent: size, range: 0.5...2).padding(.top, 8)
                StepSlider(value: size, range: 0.5...2, ticks: 7)
                    .help("How big the camera is here (100% = the recorder's Medium)")
                InspectorHeader("Shape").padding(.top, 8)
                CameraShapePicker(selected: layout.shape) { shape in edit { $0.shape = shape } }
                InspectorHeader("Position", value: layout.position.title).padding(.top, 8)
                PositionPicker(options: [.topLeft, .topRight, .bottomLeft, .bottomRight], selected: layout.position,
                               spot: CGSize(width: 18, height: 18), round: layout.shape == 0) { corner in edit { $0.position = corner } }
            } else {
                InfoBox {
                    Text(layout.kind == .full ? "The camera fills the video here and goes back into its bubble afterwards."
                                              : "The camera fades out here and comes back afterwards.")
                }
            }
            if !project.edit.camera.show {
                InfoBox { Text("The camera is turned off in the Camera section, so it doesn't show anywhere.") }
            }
            Button {
                state.selectedCamera = nil
                state.section = .camera
            } label: {
                Text("Camera Settings").font(.system(size: 13.5, weight: .medium)).frame(maxWidth: .infinity).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(W.box)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .help("The camera's look everywhere else: show, size, shape, corner, flip")
        }
    }
}

/// The recorder's four camera shapes as buttons; the selected one is blue.
private struct CameraShapePicker: View {
    let selected: Int
    let pick: (Int) -> Void
    private static let shapes: [(symbol: String, help: String)] = [
        ("circle.fill", "Circle"), ("square.fill", "Square"), ("rectangle.fill", "Rectangle"), ("rectangle.portrait.fill", "Vertical"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Self.shapes.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Image(systemName: Self.shapes[i].symbol).font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected == i ? W.blue : W.box))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Self.shapes[i].help)
            }
        }
    }
}

// MARK: - Shared controls

/// The section's main switch (the controls under it apply only while it's on).
private struct MainSwitch: View {
    let title: String
    @Binding var isOn: Bool
    let help: String
    var body: some View {
        Toggle(isOn: $isOn) { Text(title).font(.system(size: 13.5)).foregroundStyle(.white) }
            .toggleStyle(BlueSwitch())
            .help(help)
    }
}

private struct Check: View {
    let title: String
    @Binding var isOn: Bool
    let help: String
    var body: some View {
        Toggle(isOn: $isOn) { Text(title).font(.system(size: 13)).foregroundStyle(.white) }
            .toggleStyle(.checkbox)
            .help(help)
    }
}

/// A style choice: a picture in a #2A2A2A tile (blue ring when selected) with its name under it.
private struct StyleTile<Content: View>: View {
    let title: String
    let selected: Bool
    let help: String
    @ViewBuilder let content: Content
    let pick: () -> Void
    var body: some View {
        Button(action: pick) {
            VStack(spacing: 5) {
                content
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(W.box))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(selected ? W.blue : .clear, lineWidth: 2).padding(-3))
                Text(title).font(.system(size: 11)).foregroundStyle(selected ? Color.white : Color(white: 0.62))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The arrow in a cursor style: the recorded macOS arrow, or Glint's drawing.
private struct CursorPreview: View {
    let style: CursorStyle
    let project: VideoProject
    var body: some View {
        // Trimmed to the drawn pixels and shown at one height: the recorded macOS arrow sits in a large transparent
        // picture, so at its own size it looked much smaller than Glint's drawings.
        if let image, let picture = Self.trimmed(image.picture) {
            Image(decorative: picture, scale: image.scale).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit).frame(height: style == .touch ? 20 : 24)
        }
    }

    /// `image` cropped to its clearly visible pixels (alpha above ~15%, so soft shadows don't count).
    private static func trimmed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 40 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return image }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    private var image: (picture: CGImage, scale: CGFloat)? {
        if style == .system {
            // The recorded arrow (2× pictures), else today's system arrow.
            if let studio = project.studio, let i = studio.cursors.firstIndex(where: { $0.type == .arrow }), i < project.cursorImages.count,
               let picture = project.cursorImages[i] {
                return (picture, CGFloat(picture.width) / max(studio.cursors[i].width, 1))
            }
            return NSCursor.arrow.image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { ($0, 2) }
        }
        return StyledCursor.make(style).map { ($0.image, CGFloat($0.image.width) / $0.size.width) }
    }
}

/// A small frame with the spots something can sit in; the selected one is blue.
private struct PositionPicker: View {
    let options: [OverlayCorner]
    let selected: OverlayCorner
    let spot: CGSize
    var round = false
    let pick: (OverlayCorner) -> Void

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 10
            ZStack(alignment: .topLeading) {
                ForEach(options, id: \.self) { option in
                    let origin = position(option, in: geo.size, inset: inset)
                    Button { pick(option) } label: {
                        RoundedRectangle(cornerRadius: round ? spot.height / 2 : 4, style: .continuous)
                            .fill(option == selected ? W.blue : Color.white.opacity(0.14))
                            .frame(width: spot.width, height: spot.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(option.title)
                    .offset(x: origin.x, y: origin.y)
                }
            }
        }
        .frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(W.box))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(W.line, lineWidth: 1))
    }

    private func position(_ option: OverlayCorner, in size: CGSize, inset: CGFloat) -> CGPoint {
        let right = size.width - inset - spot.width, bottom = size.height - inset - spot.height
        return switch option {
        case .topLeft: CGPoint(x: inset, y: inset)
        case .topRight: CGPoint(x: right, y: inset)
        case .bottomLeft: CGPoint(x: inset, y: bottom)
        case .bottom: CGPoint(x: (size.width - spot.width) / 2, y: bottom)
        case .bottomRight: CGPoint(x: right, y: bottom)
        }
    }
}
