import AppKit
import SwiftUI

/// "All-In-One": the screen dims with the hint "Drag to select capture area." (or the last area
/// comes back when "Remember last selection" is on). Once an area is drawn, a toolbar below it picks what to do with
/// it: Area (A, Return), Fullscreen (F), Window (Space/W), Scrolling (S), Timer (T), OCR (O) or Recording (R). Its
/// right box edits the size, toggles full screen and locks an aspect ratio. Esc or a right-click cancels.
/// Recording and Scrolling hand the area over to their own selectors.
final class AllInOne {
    static let shared = AllInOne()

    enum Mode: CaseIterable {
        case area, fullscreen, window, scrolling, timer, ocr, recording

        var title: String {
            switch self {
            case .area: "Area"
            case .fullscreen: "Fullscreen"
            case .window: "Window"
            case .scrolling: "Scrolling"
            case .timer: "Timer"
            case .ocr: "OCR"
            case .recording: "Recording"
            }
        }

        /// The tooltips (they name the shortcut keys).
        var help: String {
            switch self {
            case .area: "Capture Area (A)"
            case .fullscreen: "Capture Fullscreen (F)"
            case .window: "Capture Window (Space/W)"
            case .scrolling: "Scrolling Capture (S)"
            case .timer: "Self-Timer (T)"
            case .ocr: "Capture Text (O)"
            case .recording: "Record Screen (R)"
            }
        }

        /// Keys typed while the toolbar shows (by character, so they work on any layout).
        static func forKey(_ event: NSEvent) -> Mode? {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
            if event.keyCode == 49 { return .window }  // Space
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": return .area
            case "f": return .fullscreen
            case "w": return .window
            case "s": return .scrolling
            case "t": return .timer
            case "o": return .ocr
            case "r": return .recording
            default: return nil
            }
        }

        /// Fullscreen and Window don't use the drawn area.
        var needsArea: Bool { self != .fullscreen && self != .window }
    }

    private var selector: RegionSelector?
    /// The area before the full-screen button was pressed; pressing it again goes back.
    private var areaBeforeFullScreen: CGRect?

    func start() {
        guard selector == nil, !RecordingController.shared.isRecording, Permissions.ensureScreenRecording() else { return }
        let selector = RegionSelector(hint: "Drag to select capture area.", dim: 0.5, level: NSWindow.Level(rawValue: 103))
        let model = AllInOneModel()
        selector.onChange = { [unowned selector] rect in
            model.size = rect.size
            model.isFullScreen = rect == selector.screen.cgFrame
        }
        selector.onCancel = { [weak self, unowned selector] in
            self?.remember(selector.rect)
            self?.selector = nil
        }
        selector.onConfirm = { [weak self] _ in self?.perform(.area) }
        selector.onKey = { [weak self] event in
            guard let mode = Mode.forKey(event) else { return false }
            self?.perform(mode)
            return true
        }
        let remember = Defaults[Prefs.allInOneRememberSelection]
        if !remember { Defaults[Prefs.allInOneRatio] = "" }
        selector.ratio = RecordRatio.value(Defaults[Prefs.allInOneRatio])

        model.perform = { [weak self] in self?.perform($0) }
        model.resize = { [weak selector] size in selector?.resize(to: size) }
        model.toggleFullScreen = { [weak self, weak selector] in
            guard let self, let selector else { return }
            let full = selector.screen.cgFrame
            if selector.rect == full {
                selector.set(areaBeforeFullScreen ?? full.insetBy(dx: full.width / 6, dy: full.height / 6))
                areaBeforeFullScreen = nil
            } else {
                areaBeforeFullScreen = selector.rect.isEmpty ? nil : selector.rect
                selector.set(full)
            }
        }
        model.ratioChanged = { [weak selector] in
            selector?.ratio = RecordRatio.value(Defaults[Prefs.allInOneRatio])
            selector?.applyRatio()
        }
        let host = NSHostingView(rootView: AllInOneBar(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        // Measured: the toolbar's top edge is 36pt below the area.
        selector.setAccessory(host, placement: .below(gap: 36))
        self.selector = selector
        areaBeforeFullScreen = nil
        selector.begin(initial: remember ? CGRect(storageString: Defaults[Prefs.allInOneLastArea]) : nil)
    }

    private func remember(_ rect: CGRect) {
        if !rect.isEmpty { Defaults[Prefs.allInOneLastArea] = rect.storageString }
    }

    private func perform(_ mode: Mode) {
        guard let selector else { return }
        let rect = selector.rect, screen = selector.screen
        if mode.needsArea, rect.isEmpty { NSSound.beep(); return }
        remember(rect)
        self.selector = nil
        switch mode {
        case .recording:
            selector.end()
            Defaults[Prefs.recRatio] = Defaults[Prefs.allInOneRatio]
            RecordingController.shared.toggle(initial: rect)
        case .scrolling:
            selector.end()
            ScrollingCapture.shared.start(initial: rect)
        case .window:
            selector.end()
            CaptureCoordinator.shared.captureArea(startIn: .window)
        case .fullscreen:
            selector.end(restoringFocus: true)
            // Give the window server a moment to remove the overlay before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { CaptureCoordinator.shared.captureFullscreen() }
        case .area:
            selector.end(restoringFocus: true)
            CaptureCoordinator.shared.captureSelected(rect, on: screen)
        case .timer:
            selector.end(restoringFocus: true)
            CaptureCoordinator.shared.captureSelected(rect, on: screen, timer: true)
        case .ocr:
            selector.end(restoringFocus: true)
            TextCapture.run(rect: rect, on: screen)
        }
    }
}

final class AllInOneModel: ObservableObject {
    @Published var size: CGSize = .zero
    @Published var isFullScreen = false
    var perform: (AllInOne.Mode) -> Void = { _ in }
    var resize: (CGSize) -> Void = { _ in }
    var toggleFullScreen: () -> Void = {}
    var ratioChanged: () -> Void = {}
    /// The view the ratio menu opens below.
    weak var ratioAnchor: NSView?
}

/// The All-In-One toolbar, measured at 2×: two 55.5pt boxes 12pt apart (radius 16, P3 #242426, a 0.5pt
/// #2F2F31 inner line and a 0.5pt #161617 outer line). The left one (458pt) holds the modes (61.5pt cells: 15pt
/// glyph 20.5pt from the top, 11pt label in white 60% 43.5pt from the top; hover = white 5% rounded box,
/// 61.5×42), with 36pt separators before OCR and Recording. The right one (216.5pt): W × H fields (44×22, #1D1D1E),
/// the full-screen button (18×15) and, past a separator, the aspect-ratio menu.
struct AllInOneBar: View {
    @ObservedObject var model: AllInOneModel
    @AppStorage(Prefs.allInOneRatio) private var ratio

    static let fill = Color(.displayP3, red: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x26 / 255.0)
    static let innerLine = Color(.displayP3, red: 0x2F / 255.0, green: 0x2F / 255.0, blue: 0x31 / 255.0)
    static let outerLine = Color(.displayP3, red: 0x16 / 255.0, green: 0x16 / 255.0, blue: 0x17 / 255.0)
    static let field = Color(.displayP3, red: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1E / 255.0)
    static let buttonLine = Color(.displayP3, red: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0)

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 1) {
                ForEach([AllInOne.Mode.area, .fullscreen, .window, .scrolling, .timer], id: \.self) { cell($0) }
                separator.padding(.horizontal, 2.5)
                cell(.ocr)
                separator.padding(.horizontal, 2.5)
                cell(.recording)
            }
            .padding(.horizontal, 4)
            .frame(width: 458)
            .modifier(Box())

            HStack(spacing: 0) {
                SizeField(value: Int(model.size.width), size: CGSize(width: 44, height: 22), fill: Self.field, weight: .regular, textOpacity: 0.87) {
                    model.resize(CGSize(width: CGFloat($0), height: model.size.height))
                }
                Text("×").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).frame(width: 16)
                SizeField(value: Int(model.size.height), size: CGSize(width: 44, height: 22), fill: Self.field, weight: .regular, textOpacity: 0.87) {
                    model.resize(CGSize(width: model.size.width, height: CGFloat($0)))
                }
                Button { model.toggleFullScreen() } label: {
                    Image(systemName: model.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 15)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Self.buttonLine, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(BarPressStyle())
                .help("Toggle fullscreen")
                .padding(.leading, 10)
                separator.padding(.leading, 12)
                RatioButton(model: model, ratio: ratio)
            }
            .padding(.leading, 12.5)
            .frame(width: 216.5, alignment: .leading)
            .modifier(Box(clipsContent: true))
        }
        .padding(1)
        .environment(\.colorScheme, .dark)
    }

    private var separator: some View { Rectangle().fill(Self.innerLine).frame(width: 1, height: 36) }

    private func cell(_ mode: AllInOne.Mode) -> some View {
        ModeCell(mode: mode) { model.perform(mode) }
    }

    private struct Box: ViewModifier {
        /// Clips the content to the box (the ratio segment's hover fill runs into the rounded corner).
        var clipsContent = false
        func body(content: Content) -> some View {
            content
                .frame(height: 55.5)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AllInOneBar.fill))
                .clipShape(RoundedRectangle(cornerRadius: clipsContent ? 16 : 0, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AllInOneBar.innerLine, lineWidth: 0.5))
                .background(RoundedRectangle(cornerRadius: 16.5, style: .continuous).fill(AllInOneBar.outerLine).padding(-0.5))
        }
    }
}

/// The aspect-ratio menu: the segment right of the separator (to the box's edge) lights up
/// (white 5%) while hovered or while its menu is open; the crop glyph shows the ratio (`RatioGlyph`) and the chevron
/// stays put. Measured: 59pt segment, glyph center 26pt right of the separator, chevron center 47pt.
private struct RatioButton: View {
    @ObservedObject var model: AllInOneModel
    let ratio: String
    @State private var hovered = false
    @State private var menuOpen = false

    var body: some View {
        // The menu opens on mouse-down.
        HStack(spacing: 0) {
                RatioGlyph(ratio: ratio).frame(width: 15)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(RecordPanel.gray)
                    .padding(.leading, 10.5)
            }
            .padding(.leading, 18)
            .frame(width: 59, height: 55.5, alignment: .leading)
            .background(Color.white.opacity(hovered || menuOpen ? 0.05 : 0))
            .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
            guard !menuOpen, let anchor = model.ratioAnchor else { return }
            menuOpen = true
            RecordMenus.ratio(from: anchor, pref: Prefs.allInOneRatio) { model.ratioChanged() }
            // The menu took the mouse-up; the next press opens it again.
            DispatchQueue.main.async { menuOpen = false }
        })
        .onHover { hovered = $0 }
        .background(AnchorGrabber { model.ratioAnchor = $0 })
        .help("Aspect ratio")
    }
}

/// One mode: glyph over label, a soft box on hover; pressing darkens a little more and shrinks slightly.
private struct ModeCell: View {
    let mode: AllInOne.Mode
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                AllInOneGlyph(mode: mode).frame(width: 20, height: 18).offset(y: 0.5)
                Text(mode.title).font(.system(size: 10.6, weight: .medium)).lineLimit(1).fixedSize()
                    .foregroundStyle(.white.opacity(hovered ? 0.65 : 0.6))
                    .padding(.top, 5)
            }
            .frame(width: 61.5, height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(CellPressStyle(hovered: hovered))
        .onHover { hovered = $0 }
        .help(mode.help)
    }
}

private struct CellPressStyle: ButtonStyle {
    let hovered: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.09 : hovered ? 0.05 : 0)))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct BarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.6 : 1).scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// The mode glyphs (white, ~15pt).
private struct AllInOneGlyph: View {
    let mode: AllInOne.Mode
    var body: some View {
        switch mode {
        case .area: Image(systemName: "viewfinder").font(.system(size: 16, weight: .bold))
        case .fullscreen: Image(systemName: "display").font(.system(size: 15, weight: .bold))
        case .window: Image(systemName: "macwindow").font(.system(size: 15, weight: .bold))
        case .scrolling: Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold))
        case .timer: Image(systemName: "timer").font(.system(size: 15, weight: .bold))
        case .ocr: Image(systemName: "textformat").font(.system(size: 15, weight: .bold))
        case .recording: Image(systemName: "video").font(.system(size: 14, weight: .bold))
        }
    }
}

/// Hands the underlying NSView to `grab` (menus pop up from it).
private struct AnchorGrabber: NSViewRepresentable {
    let grab: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { grab(view) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
