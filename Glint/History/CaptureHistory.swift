import AppKit
import AVFoundation
import Quartz
import SwiftUI

/// "Capture History": a blurred panel across the top of the screen with filter tabs, a "…" menu
/// (Keep History, Clear History…) and a row of past captures, newest first. Hovering (or the arrow keys) selects one;
/// clicking it restores it to Quick Access and closes the history; Return restores it and keeps the history open, so
/// several can be brought back in a row. Right-click for more. Esc or a click outside closes it.
final class CaptureHistory {
    static let shared = CaptureHistory()

    private var window: HistoryWindow?
    private var model: HistoryModel?
    private var previousApp: NSRunningApplication?

    /// `trash`: opens on the Trash instead of the history.
    func show(trash: Bool = false) {
        if let window {
            model?.setTrash(trash)
            window.makeKeyAndOrderFront(nil)
            return
        }
        HistoryStore.shared.prune()
        guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
        let model = HistoryModel(inTrash: trash)
        self.model = model
        let window = HistoryWindow(screen: screen, model: model)
        model.actions = HistoryActions(owner: self)
        self.window = window
        // SwiftUI hover (which selects items) only works while Glint is active.
        NSApp.activate()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; window.animator().alphaValue = 1 }
    }

    func close(restoreFocus: Bool = true) {
        guard let window else { return }
        self.window = nil
        model = nil
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; window.animator().alphaValue = 0 }, completionHandler: {
            window.orderOut(nil)
        })
        if restoreFocus { previousApp?.activate() }
        previousApp = nil
    }

    var isVisible: Bool { window != nil }

    /// The overlay sits above alerts and would take their clicks: it steps down while one is open.
    func runAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let level = window?.level
        window?.level = .normal
        defer { if let level { window?.level = level } }
        return alert.runModal()
    }

    /// Asks, then deletes everything in the Trash. True if it did.
    @discardableResult
    func confirmEmptyTrash() -> Bool {
        let count = HistoryStore.shared.trashCount
        guard count > 0 else { return false }
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "\(count == 1 ? "1 capture" : "\(count) captures") will be deleted for good. This can't be undone."
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard runAlert(alert) == .alertFirstButtonReturn else { return false }
        HistoryStore.shared.emptyTrash()
        return true
    }
}

enum HistoryFilter: CaseIterable {
    /// Studio: Studio Mode recordings (they stay editable), next to the videos.
    case all, screenshots, videos, studio, gifs
    var title: String {
        switch self {
        case .all: "All"
        case .screenshots: "Screenshots"
        case .videos: "Videos"
        case .gifs: "GIFs"
        case .studio: "Studio"
        }
    }
}

final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryStore.Entry]
    /// Showing the Trash instead of the history.
    @Published private(set) var inTrash: Bool
    @Published var filter: HistoryFilter = .all
    @Published var selected: URL?
    /// ⌥ is held (drag-out is off then).
    @Published var optionHeld = false
    var actions: HistoryActions?

    init(inTrash: Bool = false) {
        self.inTrash = inTrash
        entries = HistoryStore.shared.entries(inTrash: inTrash)
        selected = entries.first?.fileURL
    }

    func setTrash(_ on: Bool) {
        inTrash = on
        filter = .all
        entries = HistoryStore.shared.entries(inTrash: on)
        selected = entries.first?.fileURL
    }

    var visible: [HistoryStore.Entry] {
        switch filter {
        case .all: entries
        case .screenshots: entries.filter { !$0.isVideo && !$0.isGIF }
        case .videos: entries.filter { $0.isVideo && !$0.isProject }
        case .gifs: entries.filter(\.isGIF)
        case .studio: entries.filter(\.isProject)
        }
    }

    var selectedEntry: HistoryStore.Entry? { visible.first { $0.fileURL == selected } }

    func moveSelection(_ step: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.fileURL == selected } ?? -step
        selected = list[min(max(i + step, 0), list.count - 1)].fileURL
    }

    func reload() {
        entries = HistoryStore.shared.entries(inTrash: inTrash)
        if selectedEntry == nil { selected = visible.first?.fileURL }
    }
}

/// What the history can do with a capture.
struct HistoryActions {
    weak var owner: CaptureHistory?

    private func item(_ entry: HistoryStore.Entry) -> CaptureItem? {
        let item = CaptureItem.load(entry.fileURL, date: entry.date)
        if item == nil { NSSound.beep() }
        return item
    }

    /// ⌥: restores but keeps the history open.
    func restore(_ entry: HistoryStore.Entry, keepOpen: Bool = false) {
        guard let item = item(entry) else { return }
        if !keepOpen { owner?.close() }
        QuickAccessManager.shared.show(item)
    }

    func editVideo(_ entry: HistoryStore.Entry) {
        owner?.close()
        VideoEditorWindowController.open(url: entry.fileURL)
    }

    func saveAs(_ entry: HistoryStore.Entry) {
        guard let item = item(entry) else { return }
        owner?.close()
        _ = FileSaver.saveWithPanel(item)
    }

    func reveal(_ entry: HistoryStore.Entry) {
        owner?.close()
        NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL])
    }

    func annotate(_ entry: HistoryStore.Entry) {
        guard let item = item(entry) else { return }
        owner?.close(restoreFocus: false)
        AnnotateWindowController.open(item: item)
    }

    func pin(_ entry: HistoryStore.Entry) {
        guard let item = item(entry) else { return }
        owner?.close()
        PinManager.shared.pin(item)
    }

    func copy(_ entry: HistoryStore.Entry) {
        guard let item = item(entry) else { return }
        Clipboard.copy(item)
        owner?.close()
    }

    /// Delete: to the Trash; from the Trash, for good (asks first).
    func delete(_ entry: HistoryStore.Entry, in model: HistoryModel) {
        if model.inTrash {
            let alert = NSAlert()
            alert.messageText = "Delete “\(entry.fileURL.lastPathComponent)” for good?"
            alert.informativeText = "This can't be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            guard owner?.runAlert(alert) == .alertFirstButtonReturn else { return }
        }
        let next = neighbor(of: entry, in: model)
        if model.inTrash { HistoryStore.shared.delete(entry) } else { HistoryStore.shared.moveToTrash(entry) }
        model.selected = next?.fileURL
        model.reload()
    }

    /// Back into the history from the Trash.
    func putBack(_ entry: HistoryStore.Entry, in model: HistoryModel) {
        let next = neighbor(of: entry, in: model)
        HistoryStore.shared.putBack(entry)
        model.selected = next?.fileURL
        model.reload()
    }

    private func neighbor(of entry: HistoryStore.Entry, in model: HistoryModel) -> HistoryStore.Entry? {
        let list = model.visible
        return list.firstIndex(of: entry).flatMap { i in list.indices.contains(i + 1) ? list[i + 1] : (i > 0 ? list[i - 1] : nil) }
    }

    func quickLook() {
        let panel = QLPreviewPanel.shared()!
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }
}

/// Full-screen, transparent window above everything; the panel sits at the top.
final class HistoryWindow: NSPanel, QLPreviewPanelDataSource {
    private let model: HistoryModel

    /// The panel's frame in the window's top-left coordinates: 40pt from the screen's top and sides, 240pt tall.
    static func panelRect(in size: CGSize) -> CGRect { CGRect(x: 40, y: 40, width: size.width - 80, height: 240) }

    init(screen: NSScreen, model: HistoryModel) {
        self.model = model
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above the menu bar and the Dock but below context menus (101), so right-click menus show in front.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        animationBehavior = .none
        setFrame(screen.frame, display: false)
        contentView = NSHostingView(rootView: HistoryOverlay(model: model, size: screen.frame.size))
    }

    override var canBecomeKey: Bool { true }

    override func flagsChanged(with event: NSEvent) {
        model.optionHeld = event.modifierFlags.contains(.option)
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let entry = model.selectedEntry
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case 53: CaptureHistory.shared.close()
        case 123: model.moveSelection(-1)
        case 124: model.moveSelection(1)
        // (`where` binds to each pattern on its own: with "36, 76 where …" Return always took this branch.)
        case 36 where model.inTrash, 76 where model.inTrash: if let entry { model.actions?.putBack(entry, in: model) }
        // Return restores the selection and keeps the history open (pick the next one with the arrow keys).
        case 36, 76: if let entry { model.actions?.restore(entry, keepOpen: true) }
        case 49: if entry != nil { model.actions?.quickLook() }
        case 51, 117: if let entry { model.actions?.delete(entry, in: model) }
        case 8 where cmd && !model.inTrash: if let entry { model.actions?.copy(entry) }
        case 14 where cmd && !model.inTrash: if let entry { model.actions?.annotate(entry) }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Quick Look

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { model.selectedEntry == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { model.selectedEntry?.fileURL as NSURL? }
}

// MARK: - Views

private let accent = Color(.displayP3, red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)

struct HistoryOverlay: View {
    @ObservedObject var model: HistoryModel
    let size: CGSize

    var body: some View {
        let panel = HistoryWindow.panelRect(in: size)
        ZStack(alignment: .topLeading) {
            // A click anywhere outside the panel closes the history.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { CaptureHistory.shared.close() }
            HistoryPanel(model: model)
                .frame(width: panel.width, height: panel.height)
                .offset(x: panel.minX, y: panel.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// 20pt corners; tabs (22pt capsules ≥43.5pt wide, 13.5pt apart) centered 26pt from the top; items 185×130pt,
/// 70pt apart, starting 55pt from the left, 60pt from the top, with the time (or Restore) 23pt below.
struct HistoryPanel: View {
    @ObservedObject var model: HistoryModel

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                VisualEffect()
                Color.white.opacity(0.09)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            HStack(spacing: 13.5) {
                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                    Button { model.filter = filter; model.selected = model.visible.first?.fileURL } label: {
                        Text(filter.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.white.opacity(model.filter == filter ? 1 : 0.85))
                            .padding(.horizontal, 10.75)
                            .frame(minWidth: 43.5)
                            .frame(height: 22)
                            .background(Capsule().fill(model.filter == filter ? accent : Color.white.opacity(0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 22)
            .padding(.top, 15)
            HStack {
                if model.inTrash {
                    Button { model.setTrash(false) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                            Text("Trash").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverButtonStyle())
                    .help("Back to the history")
                    .padding(.leading, 20).padding(.top, 15)
                }
                Spacer()
                MoreButton(model: model).padding(.trailing, 20).padding(.top, 15)
            }
            strip.padding(.top, 60)
        }
    }

    @ViewBuilder private var strip: some View {
        let entries = model.visible
        if entries.isEmpty {
            Text(model.inTrash ? (model.entries.isEmpty ? "The Trash is empty" : "Nothing here") : (model.entries.isEmpty ? "No captures yet" : "Nothing here yet"))
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .padding(.top, 55)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 70) {
                        ForEach(entries) { entry in
                            HistoryItem(entry: entry, model: model).id(entry.fileURL)
                        }
                    }
                    .padding(.horizontal, 55)
                    .padding(.top, 4)
                }
                .padding(.top, -4)
                .onChange(of: model.selected) { _, url in
                    guard let url else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(url) }
                }
            }
        }
    }
}

struct HistoryItem: View {
    let entry: HistoryStore.Entry
    @ObservedObject var model: HistoryModel
    @State private var thumbnail: NSImage?
    @State private var duration: Double?

    private var isSelected: Bool { model.selected == entry.fileURL }

    var body: some View {
        VStack(spacing: 0) {
            thumb
                .frame(width: 185, height: 130)
                .onHover { if $0 { model.selected = entry.fileURL } }
                .onTapGesture {
                    // In the Trash a click only selects: Put Back is its button.
                    if model.inTrash { model.selected = entry.fileURL } else { model.actions?.restore(entry, keepOpen: NSEvent.modifierFlags.contains(.option)) }
                }
                // Holding ⌥ turns dragging off (so an ⌥-click restore can't start an accidental drag).
                .modifier(DragOut(url: entry.fileURL, enabled: !model.optionHeld))
                .contextMenu { menu }
            ZStack {
                if isSelected {
                    Button {
                        if model.inTrash { model.actions?.putBack(entry, in: model) } else { model.actions?.restore(entry) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "return").font(.system(size: 11, weight: .semibold))
                            Text(model.inTrash ? "Put Back" : "Restore").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9.5)
                        .frame(height: 22)
                        .background(Capsule().fill(accent))
                    }
                    .buttonStyle(HoverButtonStyle())
                    .offset(y: 4)
                } else {
                    Text(Self.relative(entry.date))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.42))
                }
            }
            .frame(height: 26)
            .padding(.top, 10)
        }
        .frame(width: 185)
    }

    private var thumb: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(width: 185, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                    .stroke(accent, lineWidth: 3)
                    .padding(-3.5)
                    .opacity(isSelected ? 1 : 0)
            )
            if entry.isVideo || entry.isGIF {
                // Recordings: a camera (or GIF) badge with the length, bottom left.
                HStack(spacing: 5) {
                    if entry.isGIF {
                        Text("GIF").font(.system(size: 7.5, weight: .black)).foregroundStyle(Color(white: 0.12))
                            .frame(width: 19, height: 12).background(RoundedRectangle(cornerRadius: 3).fill(.white))
                    } else {
                        Image(systemName: "video.fill").font(.system(size: 11))
                    }
                    if let duration { Text(RecordingFooter.duration(duration)).font(.system(size: 12, weight: .semibold)) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(Color(white: 0.28).opacity(0.7)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(8)
            }
            if let app = entry.sourceApp, let icon = Self.icon(for: app) {
                Image(nsImage: icon).resizable().frame(width: 25, height: 25).offset(x: 8.5, y: 9.5)
            }
        }
        .task(id: entry.fileURL) {
            thumbnail = await Self.thumbnail(entry.fileURL)
            if entry.isVideo || entry.isGIF { duration = await Self.duration(entry.fileURL, gif: entry.isGIF) }
        }
    }

    @ViewBuilder private var menu: some View {
        if model.inTrash {
            Button("Put Back") { model.actions?.putBack(entry, in: model) }.keyboardShortcut(.return, modifiers: [])
            Button("Quick Look") { model.selected = entry.fileURL; model.actions?.quickLook() }.keyboardShortcut(.space, modifiers: [])
            Divider()
            Button("Delete for Good...") { model.actions?.delete(entry, in: model) }.keyboardShortcut(.delete, modifiers: [])
        } else {
            historyMenu
        }
    }

    @ViewBuilder private var historyMenu: some View {
        if entry.isVideo || entry.isGIF {
            Button("Open Video Editor...") { model.actions?.editVideo(entry) }.keyboardShortcut("e")
        } else {
            Button("Open Annotation Tool...") { model.actions?.annotate(entry) }.keyboardShortcut("e")
        }
        Button("Pin to the Screen") { model.actions?.pin(entry) }
        Button("Quick Look") { model.selected = entry.fileURL; model.actions?.quickLook() }.keyboardShortcut(.space, modifiers: [])
        Divider()
        Button("Copy") { model.actions?.copy(entry) }.keyboardShortcut("c")
        Button("Save As...") { model.actions?.saveAs(entry) }.keyboardShortcut("s")
        Button("Show in Finder") { model.actions?.reveal(entry) }
        Button("Restore") { model.actions?.restore(entry) }.keyboardShortcut(.return, modifiers: [])
        Divider()
        Button("Move to Trash") { model.actions?.delete(entry, in: model) }.keyboardShortcut(.delete, modifiers: [])
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relative(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "Just now" : formatter.localizedString(for: date, relativeTo: Date())
    }

    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    /// A recording's length: the movie's duration, or the sum of a GIF's frame delays.
    static func duration(_ url: URL, gif: Bool) async -> Double? {
        guard gif else { return try? await AVURLAsset(url: url).load(.duration).seconds }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return (0..<CGImageSourceGetCount(source)).reduce(0.0) { sum, i in
            let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            return sum + delay
        }
    }

    static func thumbnail(_ url: URL) async -> NSImage? {
        if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: 520, height: 520)
            generator.appliesPreferredTrackTransform = true
            guard let cg = try? await generator.image(at: .zero).image else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 520,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }.value
    }
}

/// The "…" button: Keep History, the Trash and Clear History….
struct MoreButton: View {
    @ObservedObject var model: HistoryModel
    @AppStorage(Prefs.historyDays) private var days

    var body: some View {
        Menu {
            if model.inTrash {
                Button("Back to History") { model.setTrash(false) }
                Divider()
                Button("Empty Trash...") { if CaptureHistory.shared.confirmEmptyTrash() { model.reload() } }
                    .disabled(model.entries.isEmpty)
            } else {
                Section("Keep History") {
                    ForEach([(-1, "Never"), (1, "1 day"), (3, "3 days"), (7, "1 week"), (30, "1 month")], id: \.0) { value, title in
                        Toggle(title, isOn: Binding(get: { days == value }, set: { if $0 { days = value; HistoryStore.shared.prune(); model.reload() } }))
                    }
                }
                Divider()
                Button("Show Trash") { model.setTrash(true) }
                Button("Empty Trash...") { CaptureHistory.shared.confirmEmptyTrash() }
                Divider()
                Button("Clear History...") { confirmClear() }
            }
        } label: {
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.6)).frame(width: 4, height: 4) }
            }
            .frame(width: 32, height: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear Capture History?"
        alert.informativeText = "All captures in the history move to the Trash."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard CaptureHistory.shared.runAlert(alert) == .alertFirstButtonReturn else { return }
        HistoryStore.shared.clear()
        model.reload()
    }
}

/// The panel's dark blur.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// File drag-out, switched off while ⌥ is held.
private struct DragOut: ViewModifier {
    let url: URL
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() } } else { content }
    }
}
