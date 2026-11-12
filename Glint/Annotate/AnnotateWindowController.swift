import AppKit
import SwiftUI

/// The screenshot editor: the drawing tools, Share, Save as… and Done in the head bar (under the title bar and any
/// tabs); on the left the mode rail (Annotate,
/// Background, Add Image, Crop & Resize) and the sidebar with the mode's settings; the zoomable canvas; the bottom
/// action bar. Dark, in the video editor's design language.
final class AnnotateWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var open: [AnnotateWindowController] = []
    static var hasOpenEditors: Bool { !open.isEmpty }

    let doc: AnnotationDocument
    /// Called once when the editor closes: with the annotated capture after Done, otherwise with the original.
    var onFinish: ((CaptureItem) -> Void)?
    private var sourceItem: CaptureItem?
    private var finished = false
    private let canvas: AnnotationCanvasView
    private let scrollView = NSScrollView()
    private let bottomModel = AnnotateBottomBarModel()
    private weak var bottomBar: NSView?
    private var spaceMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    private var exportCache: (key: ExportKey, url: URL)?
    private var crop: CropState?
    private var cropOverlay: CropOverlayView?
    private var cropBackdrop: CropBackdropView?
    private var cropLens: CropLensView?
    private var cropScrollObserver: NSObjectProtocol?
    /// Rotations/flips done during this crop session (Cancel undoes them).
    fileprivate var cropImageEdits = 0
    /// The mode rail's choice. Crop & Resize goes back to the mode before it.
    let editorModel = AnnotateEditorModel()
    fileprivate var modeBeforeCrop: AnnotateMode = .annotate

    /// Rail, its hairline, sidebar and its hairline: the room left of the canvas.
    private static let railWidth: CGFloat = 52
    private static let sidebarWidth: CGFloat = 272
    private static var sideWidth: CGFloat { railWidth + 1 + sidebarWidth + 1 }

    // MARK: Opening

    @discardableResult
    static func open(image: CGImage, scale: CGFloat, name: String) -> AnnotateWindowController {
        let controller = AnnotateWindowController(document: AnnotationDocument(image: image, scale: scale, fileName: name))
        open.append(controller)
        updateActivationPolicy()
        NSApp.bringToFront()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.orderFrontRegardless()
        return controller
    }

    /// Opens a capture; when the editor closes, the (annotated) capture returns to Quick Access.
    @discardableResult
    static func open(item: CaptureItem) -> AnnotateWindowController {
        let name = item.fileURL.deletingPathExtension().lastPathComponent
        let controller: AnnotateWindowController
        if let saved = ImageEdit.load(for: item.fileURL) {
            // Saved from Annotate before: edit the original with its objects again.
            controller = open(image: saved.original, scale: saved.edit.scale, name: name)
            controller.doc.images = ImageEdit.images(for: item.fileURL, edit: saved.edit)
            controller.doc.restore(saved.edit)
        } else if let window = item.windowImage {
            // Window capture: edit the raw window, on the wallpaper with the padding it was captured with, or on
            // transparency (shown as a checkerboard, exported transparent).
            controller = open(image: window, scale: item.scale, name: name)
            controller.doc.isWindowCapture = true
            var style = BackgroundStyle(fill: item.windowOnWallpaper && item.windowPadding > 0 ? .wallpaper : .transparent)
            if item.windowOnWallpaper { style.padding = item.windowPadding / BackgroundStyle.maxPadding }
            controller.doc.background = style
            controller.doc.markSaved()
        } else {
            controller = open(image: item.image, scale: item.scale, name: name)
        }
        controller.sourceItem = item
        controller.onFinish = { QuickAccessManager.shared.show($0) }
        return controller
    }

    @discardableResult
    static func open(url: URL) -> AnnotateWindowController? {
        guard let file = ImageFile.load(url) else { glintLog("annotate: could not load \(url.path)"); NSSound.beep(); return nil }
        let name = url.deletingPathExtension().lastPathComponent
        if let saved = ImageEdit.load(for: url) {
            let controller = open(image: saved.original, scale: saved.edit.scale, name: name)
            controller.doc.images = ImageEdit.images(for: url, edit: saved.edit)
            controller.doc.restore(saved.edit)
            return controller
        }
        return open(image: file.image, scale: file.scale, name: name)
    }

    static func openFromPanel() {
        NSApp.bringToFront()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    static func openFromClipboard() {
        guard let image = NSImage(pasteboard: .general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { NSSound.beep(); return }
        open(image: cg, scale: image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1, name: FileNaming.name(for: Date()))
    }

    /// Shows a Dock icon while an editor is open (Annotate setting "Show Dock icon").
    private static func updateActivationPolicy() {
        let wantsDock = (!open.isEmpty || VideoEditorWindowController.hasOpenEditors) && Defaults[Prefs.annotateShowDockIcon]
        NSApp.setActivationPolicy(wantsDock ? .regular : .accessory)
    }

    // MARK: Setup

    private init(document: AnnotationDocument) {
        doc = document
        canvas = AnnotationCanvasView(document: document)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        EditorHeadBar.configure(window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior.formUnion([.moveToActiveSpace, .fullScreenPrimary])
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1000, height: 560)  // the head bar's tools and buttons and the sidebar fit
        window.title = document.fileName
        if Defaults[Prefs.annotateAlwaysOnTop] { window.level = .floating }  // until Quick Access's layering takes over
        EditorTabbing.configure(window)
        super.init(window: window)
        window.delegate = self

        buildContent()
        sizeWindowToFit()
        canvas.onToolShortcut = { [weak self] tool in self?.pickTool(tool) }
        canvas.onCommand = { [weak self] command in self?.handle(command) }
        doc.onSelectionChange = { [weak self] in self?.selectionChanged() }
        canvas.onGeometryChange = { [weak self] in self?.zoomToFit() }
        // Space-bar panning works wherever keyboard focus is in the window (except while typing text).
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.window, event.keyCode == 49, self.canvas.textView == nil,
                  !(self.window?.firstResponder is NSText) else { return event }
            if event.type == .keyDown { if !event.isARepeat, !self.canvas.spaceHeld { self.canvas.beginPanMode() } }
            else { self.canvas.endPanMode() }
            return nil
        }
        // Settings apply to open editors right away.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The window's level has one owner, which also keeps Quick Access behind the editors.
                QuickAccessManager.shared.updateLevels()
                // "Grow canvas" is one setting for every editor (bottom bar button or Settings).
                let grows = Defaults[Prefs.annotateExpandCanvas]
                if self.doc.expandsCanvas != grows { self.doc.expandsCanvas = grows }
                if self.bottomModel.growsCanvas != grows { self.bottomModel.growsCanvas = grows }
                // "Lock canvas" too.
                let locks = Defaults[Prefs.annotateLockCanvas]
                if self.doc.canvasUnlocked == locks { self.doc.canvasUnlocked = !locks }
                if self.bottomModel.locksCanvas != locks { self.bottomModel.locksCanvas = locks }
            }
        }
        DispatchQueue.main.async { [weak self] in
            // "Remember if background tool was opened": the editor opens in Background mode.
            if Defaults[Prefs.annotateRememberBackground], UserDefaults.standard.bool(forKey: "background.panelOpen") {
                self?.setMode(.background)
            }
        }

    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        // The canvas sits on the video editor's preview black.
        content.layer?.backgroundColor = NSColor(white: 0x17 / 255.0, alpha: 1).cgColor

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay  // scrollers appearing must not change the fit size
        scrollView.allowsMagnification = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

        // The title bar's band, then the head bar: tools over the workspace's middle, Share / Save as… / Done right.
        let band = EditorHeadBar.titleBand()
        let tools = ToolPickerHostingView(rootView: ToolPicker(doc: doc, onSelect: { [weak self] tool in
            self?.pickTool(tool)
            if let canvas = self?.canvas { self?.window?.makeFirstResponder(canvas) }
        }))
        tools.sizingOptions = [.intrinsicContentSize]
        let buttons = NSHostingView(rootView: AnnotateHeadButtons(doc: doc, share: { [weak self] view in self?.share(from: view) },
                                                                  saveAs: { [weak self] in self?.saveDocumentAs(nil) },
                                                                  done: { [weak self] in self?.done() }))
        buttons.sizingOptions = [.intrinsicContentSize]
        let head = EditorHeadBar(center: tools, centerInset: Self.sideWidth, trailing: buttons)

        let bar = NSHostingView(rootView: AnnotateBottomBar(model: bottomModel, actions: bottomActions))
        bottomBar = bar
        bar.translatesAutoresizingMaskIntoConstraints = false

        let rail = NSHostingView(rootView: AnnotateModeRail(model: editorModel) { [weak self] mode in self?.setMode(mode) })
        rail.sizingOptions = []
        rail.translatesAutoresizingMaskIntoConstraints = false
        let sidebar = NSHostingView(rootView: AnnotateSidebar(model: editorModel, doc: doc, crop: { [weak self] in self?.crop },
                                                              actions: sidebarActions))
        sidebar.sizingOptions = []
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let railLine = Self.solid(NSColor(white: 0x30 / 255.0, alpha: 1))
        let sidebarLine = Self.solid(NSColor(white: 0x30 / 255.0, alpha: 1))

        for view in [scrollView, rail, railLine, sidebar, sidebarLine, band, head, bar] as [NSView] { content.addSubview(view) }
        let top = head.bottomAnchor
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: content.topAnchor),
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            head.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            head.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rail.topAnchor.constraint(equalTo: top),
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rail.bottomAnchor.constraint(equalTo: bar.topAnchor),
            rail.widthAnchor.constraint(equalToConstant: Self.railWidth),
            railLine.topAnchor.constraint(equalTo: top),
            railLine.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            railLine.bottomAnchor.constraint(equalTo: bar.topAnchor),
            railLine.widthAnchor.constraint(equalToConstant: 1),
            sidebar.topAnchor.constraint(equalTo: top),
            sidebar.leadingAnchor.constraint(equalTo: railLine.trailingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bar.topAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            sidebarLine.topAnchor.constraint(equalTo: top),
            sidebarLine.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarLine.bottomAnchor.constraint(equalTo: bar.topAnchor),
            sidebarLine.widthAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: top),
            scrollView.leadingAnchor.constraint(equalTo: sidebarLine.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 51),
        ])
        window.contentView = content
    }

    private static func solid(_ color: NSColor) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func sizeWindowToFit() {
        guard let window, let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let chrome = CGSize(width: Self.sideWidth, height: 28 + EditorHeadBar.height + 51)
        let margin: CGFloat = 60
        let maxContent = CGSize(width: visible.width * 0.9 - chrome.width - margin * 2, height: visible.height * 0.88 - chrome.height - margin * 2)
        let fit = min(1, maxContent.width / doc.imageSize.width, maxContent.height / doc.imageSize.height)
        // Small (area) captures still get a roomy editor, especially in height.
        let minimum = CGSize(width: max(window.minSize.width, 1100 + Self.sideWidth / 2), height: min(760, visible.height * 0.85))
        let aspect = doc.imageSize.height / max(doc.imageSize.width, 1), room = maxContent.height / maxContent.width
        if aspect > room * 2 || aspect < room / 2 {
            // Long scrolling capture: the tallest (widest) editor, filled edge to edge by `zoomToFit`.
            window.setContentSize(CGSize(width: max(minimum.width, aspect > 1 ? 0 : maxContent.width + margin * 2 + chrome.width),
                                         height: maxContent.height + margin * 2 + chrome.height))
            window.center()
            DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
            return
        }
        let size = CGSize(width: max(minimum.width, doc.imageSize.width * fit + margin * 2 + chrome.width),
                          height: max(minimum.height, doc.imageSize.height * fit + margin * 2 + chrome.height))
        window.setContentSize(size)
        window.center()
        DispatchQueue.main.async { [weak self] in self?.setZoom(fit) }
    }

    // MARK: Actions

    private func select(_ tool: AnnotateTool) {
        // The tool rests while cropping (it comes back as it was afterwards).
        guard !doc.isCropping else { NSSound.beep(); return }
        canvas.endTextEditing()
        doc.selectedID = nil
        doc.tool = tool
    }

    /// A tool picked in the toolbar (or by its key): the sidebar shows its options.
    private func pickTool(_ tool: AnnotateTool) {
        guard !doc.isCropping else { NSSound.beep(); return }
        select(tool)
        if editorModel.mode != .annotate { setMode(.annotate) }
    }

    /// The options shown are the selected object's,
    /// otherwise the current tool's.
    var optionsTool: AnnotateTool { doc.selected.map { AnnotateTool(drawing: $0.kind) } ?? doc.tool }

    /// The sidebar shows the selection's options (they follow the document).
    private func selectionChanged() { doc.adoptStyleOfSelection() }

    // MARK: Modes

    /// The mode rail: Annotate, Background, Add Image or Crop & Resize. Another mode while cropping cancels the crop.
    func setMode(_ mode: AnnotateMode) {
        let current = editorModel.mode
        if current == .crop {
            guard mode != .crop else { return }
            modeBeforeCrop = mode
            cancelCrop()
            return
        }
        if mode == .crop { beginCrop(); return }
        editorModel.mode = mode
        // The tools work in Annotate mode only.
        doc.toolsResting = mode != .annotate
        doc.isBackgroundPanelOpen = mode == .background
        // "Remember if background tool was opened".
        UserDefaults.standard.set(mode == .background, forKey: "background.panelOpen")
        window?.makeFirstResponder(canvas)
    }

    @objc private func cropTapped() { doc.isCropping ? cancelCrop() : setMode(.crop) }

    /// Hides the editor, lets the user capture an area, then adds it.
    @objc func addScreenshot(_ sender: Any?) {
        guard let window, !doc.isCropping else { return }
        canvas.endTextEditing()
        window.orderOut(nil)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            // Glint's own selection, as in Capture Area.
            let overlay = SelectionOverlay(mode: .area)
            let result = await withCheckedContinuation { cont in overlay.begin { cont.resume(returning: $0) } }
            var image: CGImage?
            if let result {
                let rect: CGRect = switch result.target { case .area(let r): r; case .window(_, let f): f }
                try? await Task.sleep(for: .milliseconds(40))
                image = try? await ScreenCapturer.capture(rect: rect, on: result.screen, showCursor: false)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.bringToFront()
            guard let image, let scale = result?.screen.backingScaleFactor else { return }
            insertImage(image, pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        }
    }

    @objc func addImageFromFile(_ sender: Any?) {
        guard let window, !doc.isCropping else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let rep = NSImage(contentsOf: url)?.representations.first,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            self?.insertImage(image, pointSize: rep.size.width > 0 ? rep.size : CGSize(width: image.width, height: image.height))
        }
    }

    /// Debug hook: adds an image file as if chosen in Choose From File...
    func addImage(fromFile url: URL) {
        guard let rep = NSImage(contentsOf: url)?.representations.first, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        insertImage(image, pointSize: rep.size)
    }

    /// Places an image object in the middle of what's visible, no larger than the screenshot.
    private func insertImage(_ image: CGImage, pointSize: CGSize) {
        let clip = scrollView.contentView
        let center = canvas.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), from: clip)
        let limit = min(1, doc.imageSize.width / max(pointSize.width, 1), doc.imageSize.height / max(pointSize.height, 1))
        let size = CGSize(width: (pointSize.width * limit).rounded(), height: (pointSize.height * limit).rounded())
        // Selected, so it can be dragged and resized right away (outside Annotate the canvas works like Select).
        if editorModel.mode == .annotate { select(.select) }
        doc.addImage(image, size: size, center: center)
        window?.makeFirstResponder(canvas)
    }
    /// B: Background mode, or back to Annotate.
    @objc private func backgroundTapped() {
        guard !doc.isCropping else { NSSound.beep(); return }
        setMode(editorModel.mode == .background ? .annotate : .background)
    }

    private func handle(_ command: String) {
        switch command {
        case "close": window?.performClose(nil)
        case "crop": cropTapped()
        case "background": backgroundTapped()
        case "applyCrop": applyCrop()
        case "cancelCrop": cancelCrop()
        case "zoom100": setZoom(1)
        case "zoomFit": zoomToFit()
        case "zoomIn": zoom(by: 1.25)
        case "zoomOut": zoom(by: 0.8)
        default: break
        }
    }

    // MARK: Output

    private struct ExportKey: Equatable {
        let image: ObjectIdentifier
        let annotations: [Annotation]
        let background: BackgroundStyle?
        let counter: CounterSettings
        let format: ImageFormat
    }

    private var exportKey: ExportKey {
        ExportKey(image: ObjectIdentifier(doc.baseImage), annotations: doc.annotations, background: doc.displayBackground,
                  counter: doc.counter, format: Defaults[Prefs.fileFormat])
    }

    /// Renders the export ahead of time (e.g. when the pointer reaches "Drag Me") so dragging starts instantly.
    func prepareExport() {
        DispatchQueue.main.async { [weak self] in _ = self?.exportedFile() }
    }

    private func exportedFile() -> URL? {
        if let cache = exportCache, cache.key == exportKey, FileManager.default.fileExists(atPath: cache.url.path) { return cache.url }
        let key = exportKey
        guard let url = renderExportFile() else { return nil }
        exportCache = (key, url)
        return url
    }

    private func renderExportFile() -> URL? {
        guard let image = doc.renderedImage(),
              let data = ImageEncoder.data(for: image, format: Defaults[Prefs.fileFormat], scale: doc.scale) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GlintAnnotate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(doc.fileName).appendingPathExtension(Defaults[Prefs.fileFormat].fileExtension)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// Done: puts the annotated capture back into Quick Access (bottom left) and closes the editor.
    @objc private func done() {
        canvas.endTextEditing()
        var result = sourceItem
        if !doc.annotations.isEmpty || doc.isDirty, let image = doc.renderedImage(),
           let data = ImageEncoder.data(for: image, format: Defaults[Prefs.fileFormat], scale: doc.scale) {
            let url = HistoryStore.shared.newFileURL(name: doc.fileName, ext: Defaults[Prefs.fileFormat].fileExtension)
            if (try? data.write(to: url)) != nil {
                ImageEdit.store(doc, for: url)
                result = CaptureItem(image: image, scale: doc.scale, date: Date(), fileURL: url, kind: .screenshot)
                HistoryStore.shared.lastCapture = result
            }
        }
        finish(with: result)
        doc.markSaved()
        window?.close()
    }

    /// Pins the annotated image and closes the editor (editing is done).
    private func pinResult() {
        canvas.endTextEditing()
        guard let file = exportedFile(), let item = CaptureItem.load(file) else { NSSound.beep(); return }
        PinManager.shared.pin(item)
        closeAfterDrop()
    }

    /// After "Drag Me" or Pin delivered the image: close without asking to save. Quick Access gets its card back
    /// as it was (no longer "being edited"); the edited image isn't handed to it.
    private func closeAfterDrop() {
        finish(with: sourceItem)
        doc.markSaved()
        window?.close()
    }

    private func finish(with item: CaptureItem?) {
        guard !finished else { return }
        finished = true
        guard let item else { return }
        if let onFinish { onFinish(item) } else if item !== sourceItem { QuickAccessManager.shared.show(item) }
    }

    /// ⌘S: save to the export location.
    @objc func saveDocument(_ sender: Any?) {
        canvas.endTextEditing()
        guard let file = exportedFile() else { NSSound.beep(); return }
        let target = FileSaver.uniqueURL(FileSaver.exportDirectory.appendingPathComponent(file.lastPathComponent))
        do {
            try FileManager.default.copyItem(at: file, to: target)
            ImageEdit.store(doc, for: target)
            doc.markSaved()
            SoundPlayer.playShutter()
        } catch { NSSound.beep() }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        canvas.endTextEditing()
        guard let window, let file = exportedFile() else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.directoryURL = FileSaver.exportDirectory
        let chooser = SaveFormatChooser(panel: panel, format: Defaults[Prefs.fileFormat])
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let doc = self?.doc else { return }
            guard let image = doc.renderedImage(), let data = ImageEncoder.data(for: image, format: chooser.format, scale: doc.scale),
                  (try? data.write(to: url)) != nil else { NSSound.beep(); return }
            ImageEdit.store(doc, for: url)
            doc.markSaved()
        }
    }

    /// ⌘C / ⇧⌘C: copy the annotated screenshot.
    @objc func copy(_ sender: Any?) {
        canvas.endTextEditing()
        guard let file = exportedFile(), let image = doc.renderedImage() else { NSSound.beep(); return }
        Clipboard.copy(CaptureItem(image: image, scale: doc.scale, date: Date(), fileURL: file, kind: .screenshot))
    }

    /// File → Copy Screenshot (⇧⌘C). Its own action: with the standard `copy:` in the File menu, macOS took that
    /// menu for the Edit menu and put AutoFill, Dictation and Emoji & Symbols into it.
    @objc func copyScreenshot(_ sender: Any?) { copy(sender) }

    private var bottomActions: AnnotateBottomBar.Actions {
        AnnotateBottomBar.Actions(
            zoomIn: { [weak self] in self?.zoom(by: 1.25) },
            zoomOut: { [weak self] in self?.zoom(by: 0.8) },
            actualSize: { [weak self] in self?.setZoom(1) },
            zoomToFit: { [weak self] in self?.zoomToFit() },
            setZoom: { [weak self] in self?.setZoom($0) },
            toggleGrowCanvas: { Defaults[Prefs.annotateExpandCanvas].toggle() },
            toggleLockCanvas: { Defaults[Prefs.annotateLockCanvas].toggle() },
            pin: { [weak self] in self?.pinResult() },
            copy: { [weak self] in self?.copy(nil) },
            dragFile: { [weak self] in self?.canvas.endTextEditing(); return self?.exportedFile() },
            prepareDrag: { [weak self] in self?.prepareExport() },
            dropped: { [weak self] in self?.closeAfterDrop() }
        )
    }

    private func share(from view: NSView) {
        guard let file = exportedFile() else { return }
        NSSharingServicePicker(items: [file]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func zoom(by factor: CGFloat) { setZoom(scrollView.magnification * factor) }

    /// Sets the zoom and recenters the image (the clip view centers it when it fits; otherwise scroll to the middle).
    /// `atStart`: show the top (left) end instead of the middle (long scrolling captures).
    func setZoom(_ value: CGFloat, atStart: Bool = false) {
        if doc.isCropping { cropZoom(value); return }
        let clamped = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.magnification = clamped
        let clip = scrollView.contentView
        let visible = clip.bounds.size
        let canvasSize = doc.layout.canvasSize
        let frame = canvas.frame
        let origin = atStart ? frame.origin
            : CGPoint(x: frame.minX + (canvasSize.width - visible.width) / 2, y: frame.minY + (canvasSize.height - visible.height) / 2)
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: visible)).origin)
        scrollView.reflectScrolledClipView(clip)
        bottomModel.zoom = clamped
    }

    func zoomToFit() {
        if doc.isCropping { cropZoomToFit(); return }
        let available = scrollView.frame.size
        // Scale until one side of the canvas meets the edge of the visible area.
        let canvasSize = doc.layout.canvasSize
        // In crop mode leave room around the image for the handles.
        let inset: CGFloat = doc.isCropping ? 120 : 0
        let fitWidth = (available.width - inset) / canvasSize.width, fitHeight = (available.height - inset) / canvasSize.height
        let fit = min(fitWidth, fitHeight)
        // A long scrolling capture would shrink to a sliver: it fits the left, top and right edges instead (sideways
        // ones: top, left and bottom), at most 100% so narrow captures aren't blown up, and scrolls along its length
        // from the top (left) end. The scroll view's elasticity lets it overshoot a little at both ends and spring back.
        // Long means the image itself (over 2.5 times longer than wide), not just taller than the window's shape:
        // a 2:3 backdrop still fits whole.
        let aspect = canvasSize.height / max(canvasSize.width, 1)
        if !doc.isCropping, aspect > 2.5, fitHeight < fitWidth / 2 {
            setZoom(min(fitWidth, 1), atStart: true)
        } else if !doc.isCropping, aspect < 0.4, fitWidth < fitHeight / 2 {
            setZoom(min(fitHeight, 1), atStart: true)
        } else {
            setZoom(fit)
        }
    }

    @objc private func magnificationChanged() {
        bottomModel.zoom = scrollView.magnification
        if doc.isCropping { updateCropRoom(growOnly: true) }
    }

    // MARK: Undo

    @objc func undo(_ sender: Any?) {
        canvas.endTextEditing()
        if doc.undoManager.canUndo { doc.undoManager.undo() } else { NSSound.beep() }
    }

    @objc func redo(_ sender: Any?) {
        if doc.undoManager.canRedo { doc.undoManager.redo() } else { NSSound.beep() }
    }

    @objc func delete(_ sender: Any?) { doc.deleteSelected() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = doc.undoManager.undoMenuItemTitle
            return doc.undoManager.canUndo
        case #selector(redo(_:)):
            menuItem.title = doc.undoManager.redoMenuItemTitle
            return doc.undoManager.canRedo
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { doc.undoManager }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.endTextEditing()
        guard doc.isDirty, !doc.annotations.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to this screenshot?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: saveDocument(nil); return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    /// New Tab (⌘T, or + in the tab bar).
    override func newWindowForTab(_ sender: Any?) { EditorTabbing.newTab(from: window) }

    func windowWillClose(_ notification: Notification) {
        if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if sourceItem != nil { finish(with: sourceItem) }  // closed without Done: the original comes back
        Self.open.removeAll { $0 === self }
        Self.updateActivationPolicy()
    }
}

/// Keeps the canvas centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if rect.width > frame.width { rect.origin.x = frame.midX - rect.width / 2 }
        if rect.height > frame.height { rect.origin.y = frame.midY - rect.height / 2 }
        return rect
    }
}

/// Small images for the sidebar and menus.
enum SwatchImage {
    static func colorWheel(diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter + 6, height: diameter + 6)
        return NSImage(size: size, flipped: false) { rect in
            let c = rect.insetBy(dx: 3, dy: 3)
            let center = CGPoint(x: c.midX, y: c.midY)
            for i in 0..<36 {
                let a0 = CGFloat(i) / 36 * 360, a1 = CGFloat(i + 1) / 36 * 360 + 1
                let path = NSBezierPath()
                path.move(to: center)
                path.appendArc(withCenter: center, radius: c.width / 2, startAngle: a0, endAngle: a1)
                path.close()
                NSColor(hue: CGFloat(i) / 36, saturation: 0.85, brightness: 1, alpha: 1).setFill()
                path.fill()
            }
            NSGradient(colors: [.white, .white.withAlphaComponent(0)])?.draw(in: NSBezierPath(ovalIn: c), relativeCenterPosition: .zero)
            return true
        }
    }

    /// "Transparent": a circle of checker quarters (light and gray), for the fill menu.
    static func transparentCircle(diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter + 6, height: diameter + 6)
        return NSImage(size: size, flipped: false) { rect in
            let c = rect.insetBy(dx: 3, dy: 3)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: c).addClip()
            NSColor(white: 0.92, alpha: 1).setFill()
            c.fill()
            NSColor(white: 0.6, alpha: 1).setFill()
            CGRect(x: c.minX, y: c.midY, width: c.width / 2, height: c.height / 2).fill()
            CGRect(x: c.midX, y: c.minY, width: c.width / 2, height: c.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}

// MARK: - Sidebar actions

extension AnnotateWindowController {
    var sidebarActions: AnnotateSidebarActions {
        AnnotateSidebarActions(
            setColor: { [weak self] color in
                guard let self else { return }
                self.doc.color = color
                self.canvas.styleChanged()
            },
            customColor: { [weak self] in
                guard let self else { return }
                let panel = NSColorPanel.shared
                panel.setTarget(self)
                panel.setAction(#selector(self.colorPanelChangedForSidebar(_:)))
                panel.color = self.doc.color.nsColor
                panel.orderFront(nil)
            },
            setThickness: { [weak self] step in
                guard let self else { return }
                // Counters share one size; the thickness steps pick it.
                if self.optionsTool == .counter {
                    self.doc.changeCounter { $0.setThicknessStep(step) }
                } else {
                    self.doc.thickness = step
                    self.canvas.styleChanged()
                }
            },
            setFontSize: { [weak self] size in
                self?.doc.fontSize = size
                self?.canvas.styleChanged()
            },
            setArrowStyle: { [weak self] style in self?.doc.arrowStyle = style; self?.restyleSelection() },
            setTextStyle: { [weak self] style in self?.doc.textStyle = style; self?.restyleSelection() },
            setRedactMode: { [weak self] mode in self?.doc.redactMode = mode; self?.restyleSelection() },
            setSpotlightShape: { [weak self] shape in self?.doc.spotlightShape = shape; self?.restyleSelection() },
            setCounterStyle: { [weak self] style in self?.doc.changeCounter { $0.style = style } },
            setCounterStart: { [weak self] start in self?.doc.counter.start = start },
            setCounterSize: { [weak self] size in self?.doc.changeCounter { $0.size = size } },
            setAmount: { [weak self] value in self?.doc.redactAmount = value; self?.restyleSelection() },
            setSpotlightBrightness: { [weak self] value in self?.doc.spotlightBrightness = value; self?.restyleSelection() },
            setSpotlightRest: { [weak self] value in self?.doc.spotlightRest = value; self?.restyleSelection() },
            setSpotlightKeepsAnnotations: { [weak self] keeps in self?.doc.spotlightKeepsAnnotations = keeps; self?.restyleSelection() },
            setSpotlightSoftness: { [weak self] value in self?.doc.spotlightSoftness = value; self?.restyleSelection() },
            setSpotlightBorder: { [weak self] on in self?.doc.spotlightBorder = on; self?.restyleSelection() },
            setHandDrawn: { [weak self] change in
                guard let self else { return }
                change(self.doc)
                self.restyleSelection()
            },
            setMagnifier: { [weak self] change in
                guard let self else { return }
                change(self.doc)
                self.restyleSelection()
            },
            setEmoji: { [weak self] emoji in self?.doc.emoji = emoji },
            setEmojiSize: { [weak self] size in self?.doc.emojiSize = size },
            takeScreenshot: { [weak self] in self?.addScreenshot(nil) },
            chooseImage: { [weak self] in self?.addImageFromFile(nil) },
            setCropRatio: { [weak self] ratio in self?.crop?.apply(ratio) },
            setCropFill: { [weak self] fill in
                self?.crop?.fill = fill
                self?.updateCropFill()
            },
            customCropFill: { [weak self] in self?.cropCustomFill() },
            rotate: { [weak self] in self?.transformCropImage(rotate: true) },
            flip: { [weak self] in self?.transformCropImage(rotate: false) },
            cancelCrop: { [weak self] in self?.cancelCrop() },
            applyCrop: { [weak self] in self?.applyCrop() }
        )
    }

    @objc fileprivate func colorPanelChangedForSidebar(_ sender: NSColorPanel) {
        doc.color = AnnotationColor(sender.color)
        canvas.styleChanged()
    }

    /// Applies the sidebar's options to the selected object (the options shown are always the selection's).
    fileprivate func restyleSelection() {
        if doc.selected != nil || doc.editingTextID != nil { canvas.styleChanged() }
    }
}

extension SwatchImage {
    /// "Text" rendered in a text style, for the style choices.
    static func textStyleSample(_ style: TextStyle, color: AnnotationColor = AnnotationColor(hex: 0x8E8E93)) -> NSImage {
        let size: CGFloat = 15
        let font = style.font(size: size)
        let textSize = AnnotationRenderer.styledTextSize("Text", size: size, style: style)
        let image = NSImage(size: NSSize(width: 52, height: 24), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let origin = CGPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2)
            AnnotationRenderer.drawStyledText("Text", at: origin, size: size, color: color, style: style, ctx: ctx)
            _ = font
            return true
        }
        return image
    }
}

// MARK: - Crop & Resize mode

extension AnnotateWindowController {
    /// Crop & Resize: the sidebar shows its settings, the tools rest; Cancel, Crop or another mode ends it.
    func beginCrop() {
        guard window != nil, !doc.isCropping else { return }
        canvas.endTextEditing()
        doc.selectedID = nil
        // Crop works on the screenshot itself; the background is hidden meanwhile and kept afterwards.
        let state = CropState(imageSize: doc.imageSize)
        state.pixelScale = doc.scale
        // Freeform, unless this screenshot was cropped with a ratio before: that one stays.
        if let last = doc.cropRatio {
            state.ratio = last.ratio
            state.typedRatio = last.typed
        }
        crop = state
        doc.isCropping = true
        doc.backgroundBeforeCrop = doc.background
        cropImageEdits = 0
        // Background mode would edit that room: it's left while cropping and comes back afterwards.
        modeBeforeCrop = editorModel.mode
        doc.isBackgroundPanelOpen = false
        editorModel.mode = .crop

        let overlay = CropOverlayView(state: state)
        overlay.magnification = { [weak self] in self?.scrollViewMagnification ?? 1 }
        // The room grows with the frame and never shrinks while cropping: shrinking it moved the view (the canvas
        // origin shifted under the clip view), which made the view jump after a drag.
        overlay.onRectChange = { [weak self] _ in self?.updateCropRoom(growOnly: true) }
        overlay.onHandleDrag = { [weak self] anchor, pointer in self?.showCropLens(anchor: anchor, pointer: pointer) }
        overlay.onHandleDragEnd = { [weak self] in self?.hideCropLens() }
        canvas.addSubview(overlay)
        cropOverlay = overlay
        canvas.isCropRoom = true
        let backdrop = CropBackdropView(state: state, canvas: canvas)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        scrollView.superview?.addSubview(backdrop, positioned: .below, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: scrollView.topAnchor), backdrop.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor), backdrop.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])
        cropBackdrop = backdrop
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        cropScrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cropBackdrop?.needsDisplay = true
                // The handles keep their size on screen: redraw them (and their hit areas) at every zoom step.
                if let overlay = self.cropOverlay {
                    overlay.needsDisplay = true
                    self.window?.invalidateCursorRects(for: overlay)
                }
            }
        }
        // The crop may go anywhere: the screenshot sits in a room as big as the view (and the frame) need, filled
        // like the result.
        updateCropRoom()
        updateCropFill()

        window?.makeFirstResponder(canvas)
        DispatchQueue.main.async { self.zoomToFit() }
    }

    /// The lens beside the pointer, on whichever side has room.
    private func showCropLens(anchor: CGPoint, pointer: CGPoint) {
        guard let state = crop, let overlay = cropOverlay, let host = scrollView.superview else { return }
        let lens = cropLens ?? {
            let lens = CropLensView(state: state)
            host.addSubview(lens, positioned: .above, relativeTo: scrollView)
            cropLens = lens
            return lens
        }()
        if lens.image == nil { lens.image = doc.flattened() }
        lens.anchor = anchor
        let p = overlay.convert(pointer, to: host), area = scrollView.frame, side = CropLensView.side, gap: CGFloat = 30
        var origin = CGPoint(x: p.x + gap, y: p.y + gap)
        if origin.x + side > area.maxX { origin.x = p.x - gap - side }
        if origin.y + side > area.maxY { origin.y = p.y - gap - side }
        lens.frame.origin = CGPoint(x: min(max(origin.x, area.minX + 8), area.maxX - side - 8), y: min(max(origin.y, area.minY + 8), area.maxY - side - 8))
        if lens.alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; lens.animator().alphaValue = 1 } }
    }

    private func hideCropLens() {
        guard let lens = cropLens else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; lens.animator().alphaValue = 0 }
    }

    func cancelCrop() { endCrop(apply: false) }

    @objc func applyCrop() { endCrop(apply: true) }

    private func endCrop(apply: Bool) {
        guard let state = crop else { return }
        if apply, let flat = doc.flattened(), let result = state.render(flat, scale: doc.scale) {
            doc.replaceImage(result, name: "Crop")
            doc.cropRatio = (state.ratio, state.ratio == .customRatio ? state.typedRatio : nil)
        } else if !apply {
            for _ in 0..<cropImageEdits where doc.undoManager.canUndo { doc.undoManager.undo() }
        }
        cropImageEdits = 0
        let restored = doc.backgroundBeforeCrop
        doc.isCropping = false
        doc.background = restored
        cropOverlay?.removeFromSuperview()
        cropBackdrop?.removeFromSuperview()
        cropBackdrop = nil
        cropLens?.removeFromSuperview()
        cropLens = nil
        if let cropScrollObserver { NotificationCenter.default.removeObserver(cropScrollObserver) }
        cropScrollObserver = nil
        canvas.isCropRoom = false
        cropOverlay = nil
        // Back to the mode before (the sidebar no longer needs the crop's state).
        editorModel.mode = modeBeforeCrop
        doc.isBackgroundPanelOpen = modeBeforeCrop == .background
        doc.toolsResting = modeBeforeCrop != .annotate
        crop = nil
        canvas.window?.makeFirstResponder(canvas)
        DispatchQueue.main.async { self.zoomToFit() }
    }

    fileprivate var scrollViewMagnification: CGFloat { canvas.enclosingScrollView?.magnification ?? 1 }

    /// The crop backdrop shows the fill (the sidebar's Fill).
    fileprivate func updateCropFill() {
        guard let state = crop else { return }
        cropBackdrop?.fill = state.fillColor(for: doc.baseImage)
    }

    @objc fileprivate func cropCustomFill() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(cropFillColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func cropFillColorChanged(_ sender: NSColorPanel) {
        guard crop != nil else { return }
        crop?.fill = .custom(AnnotationColor(sender.color).hex)
        updateCropFill()
    }

    /// Rotate and Flip turn the screenshot right away, annotations included (they stay editable). Each is an undo step; Cancel undoes them.
    fileprivate func transformCropImage(rotate: Bool) {
        guard let state = crop else { return }
        doc.transform(rotate: rotate)
        cropLens?.image = nil
        cropImageEdits += 1
        state.imageTransformed(rotated: rotate, newSize: doc.imageSize)
        layOutCropRoom()
    }

    fileprivate func layOutCropRoom() {
        updateCropRoom(growOnly: true)
        updateCropFill()
        DispatchQueue.main.async { self.zoomToFit() }
    }

    /// The room around the screenshot while cropping: the screenshot and the frame plus a view's worth on every side,
    /// so the fill seems endless. Growing it on the left/top shifts the canvas; the view is scrolled along so nothing
    /// moves on screen. `growOnly` only ever enlarges it: every call while cropping uses it, since shrinking the room
    /// moved the view (after drags, fill changes, zooms); only the first one sizes it from scratch.
    func updateCropRoom(growOnly: Bool = false) {
        guard let state = crop else { return }
        let image = CGRect(origin: .zero, size: state.imageSize)
        let content = image.union(state.rect)
        let visible = scrollView.contentView.bounds.size
        let pad = min(max(visible.width, visible.height, 200), 6000)
        var room = content.insetBy(dx: -pad, dy: -pad).integral
        let e = doc.background?.expansion ?? BackgroundStyle.Insets()
        let current = CGRect(x: -e.left, y: -e.top, width: image.width + e.left + e.right, height: image.height + e.top + e.bottom)
        if growOnly {
            guard !current.contains(content.insetBy(dx: -pad / 2, dy: -pad / 2)) else { return }
            room = room.union(current)
        }
        // The room itself draws nothing: the backdrop behind the scroll view shows the fill.
        cropBackdrop?.fill = state.fillColor(for: doc.baseImage)
        var bg = BackgroundStyle(fill: .transparent)
        bg.expansion = BackgroundStyle.Insets(top: -room.minY, left: -room.minX, bottom: room.maxY - image.height, right: room.maxX - image.width)
        cropOverlay?.frame = room
        cropOverlay?.bounds = room
        cropOverlay?.needsDisplay = true
        guard bg != doc.background else { return }
        let before = doc.layout.imageOrigin
        doc.background = bg
        canvas.syncGeometry()
        let after = doc.layout.imageOrigin, clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x += after.x - before.x
        origin.y += after.y - before.y
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Zoom while cropping: keeps `center` (screenshot points; nil = the middle of the view) in the middle.
    func cropZoom(_ value: CGFloat, center: CGPoint? = nil) {
        let clip = scrollView.contentView
        let c = center ?? canvas.convert(CGPoint(x: clip.bounds.midX, y: clip.bounds.midY), from: clip)
        scrollView.magnification = min(max(value, scrollView.minMagnification), scrollView.maxMagnification)
        updateCropRoom(growOnly: true)
        let p = canvas.convert(c, to: clip)
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: CGPoint(x: p.x - clip.bounds.width / 2, y: p.y - clip.bounds.height / 2),
                                                        size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
        bottomModel.zoom = scrollView.magnification
    }

    /// Fit while cropping: the screenshot and the frame, with room for the handles.
    func cropZoomToFit() {
        guard let state = crop else { return }
        let content = CGRect(origin: .zero, size: state.imageSize).union(state.rect)
        let available = scrollView.frame.size
        let fit = min((available.width - 120) / content.width, (available.height - 120) / content.height)
        cropZoom(fit, center: CGPoint(x: content.midX, y: content.midY))
    }
}

/// Shared look of the Annotate/crop toolbar controls.
enum BarStyle {
    static let fill = Color.white.opacity(0.2)
    static let secondary = Color.white.opacity(0.5)
    static let font = Font.system(size: 13, weight: .medium)
}

/// Plain-digit number parsing for the crop fields: "1.600" and "1,600" are 1600 (a localized formatter read the
/// German "1.600" as 1); a single separator followed by one or two digits is a decimal ("1.5").
enum CropNumber {
    static func parse(_ text: String) -> CGFloat? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 2, (1...2).contains(parts[1].count), let v = Double(t) { return CGFloat(v) }
        guard let v = Double(t.filter(\.isNumber)) else { return nil }
        return CGFloat(v)
    }

    static func text(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", Double(v)).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
}

/// A draft text field that applies on Return or when it loses focus, showing `current` otherwise.
struct CropDraftField: View {
    let current: String
    var placeholder = ""
    var width: CGFloat = 34
    let commit: (String) -> Void
    @State private var draft = ""
    /// What Return last applied, so leaving the field afterwards doesn't apply it again.
    @State private var submitted: String?
    @FocusState private var focused: Bool
    /// While typing: a click anywhere but in the field ends it (and applies the value), like Return.
    @State private var clickMonitor: Any?

    var body: some View {
        TextField(placeholder, text: $draft)
            .focused($focused)
            .onSubmit { commit(draft); submitted = draft }
            .onAppear { draft = current }
            .onChange(of: current) { _, value in draft = value }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                        if let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor,
                           editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) { return event }
                        DispatchQueue.main.async { focused = false }
                        return event
                    }
                    return
                }
                if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
                clickMonitor = nil
                if draft != current, draft != submitted { commit(draft) }
                submitted = nil
                draft = current
            }
            .textFieldStyle(.plain)
            .font(BarStyle.font)
            .foregroundStyle(Color(white: 0.9))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: width)
    }
}

/// One term of the crop ratio (empty while the ratio is Custom). Typing "1:2" in either field sets both.
struct CropRatioField: View {
    @Bindable var state: CropState
    let width: Bool

    var body: some View {
        let terms = state.ratioTerms
        CropDraftField(current: width ? terms.0 : terms.1) { text in
            let pair = text.split(separator: ":")
            if pair.count == 2, let a = CropNumber.parse(String(pair[0])), let b = CropNumber.parse(String(pair[1])) {
                // "a:b" is always width:height; the other field first, so the edited axis is the one that changes.
                state.setRatioTerm(width ? b : a, width: !width)
                state.setRatioTerm(width ? a : b, width: width)
                return
            }
            let value = CropNumber.parse(text)
            guard value != nil || text.isEmpty else { return }
            state.setRatioTerm(value, width: width)
        }
    }
}

/// Share, Save as… and Done in the head bar: off (dimmed) while cropping, like the tools.
struct AnnotateHeadButtons: View {
    let doc: AnnotationDocument
    let share: (NSView) -> Void
    let saveAs: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HeadShareButton(help: "Share", action: share)
                .disabled(doc.isCropping)
                .opacity(doc.isCropping ? 0.45 : 1)
            CropAwareBarButton(doc: doc, title: "Save as...", tip: "Save as... Choose export location and file name", prominent: false, action: saveAs)
            CropAwareBarButton(doc: doc, title: "Done", tip: "Finish editing and show it in Quick Access", prominent: true, action: done)
        }
        .fixedSize()
    }
}

/// Save as… / Done: off (dimmed) while cropping, like the tools.
struct CropAwareBarButton: View {
    let doc: AnnotationDocument
    let title: String
    let tip: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(BarTextButtonStyle(prominent: prominent))
            .help(doc.isCropping ? "Finish Crop & Resize first (Crop or Cancel in the sidebar)" : tip)
            .disabled(doc.isCropping)
            .opacity(doc.isCropping ? 0.45 : 1)
    }
}
