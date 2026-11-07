import AppKit
import SwiftUI

/// The screenshot and video editors share one kind of tab: their windows (and New Tab's chooser) can be tabs of the
/// same window. Settings → Annotate → "Open editors in tabs" overrides macOS's "Prefer tabs" for them.
enum EditorTabbing {
    static let identifier = "GlintEditor"

    static var mode: NSWindow.TabbingMode {
        switch Defaults[Prefs.editorTabs] {
        case .system: .automatic
        case .always: .preferred
        case .never: .disallowed
        }
    }

    static func configure(_ window: NSWindow) {
        window.tabbingIdentifier = identifier
        window.tabbingMode = mode
    }

    /// The setting changed: open editors follow it for the windows they open next.
    static func apply() {
        for window in NSApp.windows where window.tabbingIdentifier == identifier { window.tabbingMode = mode }
    }

    /// New Tab (⌘T or the + in the tab bar): a chooser as a new tab of `window`.
    static func newTab(from window: NSWindow?) {
        let chooser = NewTabWindowController()
        if let window, let tab = chooser.window, mode != .disallowed {
            window.addTabbedWindow(tab, ordered: .above)
        } else {
            chooser.window?.center()
        }
        chooser.showWindow(nil)
        chooser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The editor that replaces a chooser: it takes the chooser's place in the tabs.
    static func replace(_ chooser: NSWindow, with editor: NSWindow?) {
        if let editor, editor !== chooser {
            if mode != .disallowed, editor.tabGroup !== chooser.tabGroup { chooser.addTabbedWindow(editor, ordered: .above) }
            editor.makeKeyAndOrderFront(nil)
        }
        chooser.close()
    }
}

/// New Tab's window: the latest captures to pick from, or Choose File….
final class NewTabWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [NewTabWindowController] = []
    private let model = NewTabModel()

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        EditorHeadBar.configure(window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.title = "New Tab"
        EditorTabbing.configure(window)
        super.init(window: window)
        window.delegate = self
        let band = EditorHeadBar.titleBand()
        let host = NSHostingView(rootView: NewTabView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0x21 / 255.0, alpha: 1).cgColor
        content.addSubview(band)
        content.addSubview(host)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: content.topAnchor),
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            host.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        model.open = { [weak self] url in self?.openFile(url) }
        model.chooseFile = { [weak self] in self?.chooseFile() }
        Self.open.append(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func newWindowForTab(_ sender: Any?) { EditorTabbing.newTab(from: window) }

    private func chooseFile() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .gif]
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.openFile(url) }
        }
    }

    /// Opens the file in its editor, in this tab's place. GIFs open in the GIF trimmer, a window of its own.
    private func openFile(_ url: URL) {
        guard let chooser = window else { return }
        switch url.pathExtension.lowercased() {
        case "gif":
            GIFTrimmer.open(url: url)
            chooser.close()
        case "mp4", "mov", "m4v":
            model.opening = true
            VideoEditorWindowController.open(url: url, opened: { editor in EditorTabbing.replace(chooser, with: editor) })
            // A movie that can't be opened beeps; the chooser stays usable.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.model.opening = false }
        default:
            let isCapture = url.path.hasPrefix(HistoryStore.shared.directory.path)
            let controller = isCapture ? CaptureItem.load(url, date: Date()).map { AnnotateWindowController.open(item: $0) }
                                       : AnnotateWindowController.open(url: url)
            EditorTabbing.replace(chooser, with: controller?.window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

@Observable
final class NewTabModel {
    enum Filter: String, CaseIterable { case all = "All", screenshots = "Screenshots", videos = "Videos" }
    var filter = Filter.all
    var entries = HistoryStore.shared.entries()
    var opening = false
    @ObservationIgnored var open: (URL) -> Void = { _ in }
    @ObservationIgnored var chooseFile: () -> Void = {}

    var visible: [HistoryStore.Entry] {
        switch filter {
        case .all: entries
        case .screenshots: entries.filter { !$0.isVideo && !$0.isGIF }
        case .videos: entries.filter { $0.isVideo || $0.isGIF }
        }
    }
}

/// The chooser: a filter, the Capture History as a grid (newest first), and Choose File….
private struct NewTabView: View {
    let model: NewTabModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Open in a new tab").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: Bindable(model).filter) {
                    ForEach(NewTabModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button("Choose File…", action: model.chooseFile)
                    .buttonStyle(BarTextButtonStyle(prominent: true))
                    .keyboardShortcut("o")
                    .help("Open an image or video from your Mac")
            }
            .padding(.horizontal, 20)
            .frame(height: EditorHeadBar.height)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0x30 / 255.0)).frame(height: 1) }

            if model.visible.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("No captures in the Capture History yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)], spacing: 18) {
                        ForEach(model.visible) { entry in
                            NewTabItem(entry: entry) { model.open(entry.fileURL) }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .disabled(model.opening)
        .overlay { if model.opening { ProgressView().controlSize(.large) } }
        .background(Color(white: 0x21 / 255.0))
        .environment(\.colorScheme, .dark)
    }
}

private struct NewTabItem: View {
    let entry: HistoryStore.Entry
    let action: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0x17 / 255.0))
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).padding(6)
                    }
                    if entry.isVideo || entry.isGIF {
                        Image(systemName: entry.isGIF ? "photo.stack" : (entry.isProject ? "video.badge.waveform" : "video.fill"))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .padding(5).background(Circle().fill(.black.opacity(0.55)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(8)
                    }
                }
                .aspectRatio(1.45, contentMode: .fit)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? Color.white.opacity(0.55) : Color(white: 0x30 / 255.0), lineWidth: hovering ? 1.5 : 1))
                .scaleEffect(hovering ? 1.02 : 1)
                Text(entry.fileURL.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(HistoryItem.relative(entry.date)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(entry.isVideo ? "Open in the video editor" : entry.isGIF ? "Open in the GIF editor" : "Open in the screenshot editor")
        .task(id: entry.fileURL) { thumbnail = await HistoryItem.thumbnail(entry.fileURL) }
    }
}
