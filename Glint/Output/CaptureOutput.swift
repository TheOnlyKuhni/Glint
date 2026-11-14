import AppKit
import UniformTypeIdentifiers

/// What should happen after a capture, either from settings or forced by a shortcut like "Capture Area & Save".
struct AfterCaptureOptions {
    var showQuickAccess: Bool
    var copyToClipboard: Bool
    var save: Bool
    var openAnnotate: Bool
    var pin: Bool

    static func fromSettings(_ kind: CaptureKind = .screenshot) -> AfterCaptureOptions {
        AfterCaptureOptions(showQuickAccess: Defaults[Prefs.afterCapture(.showQuickAccess, kind)],
                            copyToClipboard: Defaults[Prefs.afterCapture(.copyToClipboard, kind)],
                            save: Defaults[Prefs.afterCapture(.save, kind)],
                            openAnnotate: Defaults[Prefs.afterCapture(.openAnnotate, kind)],
                            pin: Defaults[Prefs.afterCapture(.pin, kind)])
    }

    static let copyOnly = AfterCaptureOptions(showQuickAccess: false, copyToClipboard: true, save: false, openAnnotate: false, pin: false)
    static let saveOnly = AfterCaptureOptions(showQuickAccess: false, copyToClipboard: false, save: true, openAnnotate: false, pin: false)
    static let annotateOnly = AfterCaptureOptions(showQuickAccess: false, copyToClipboard: false, save: false, openAnnotate: true, pin: false)
    static let pinOnly = AfterCaptureOptions(showQuickAccess: false, copyToClipboard: false, save: false, openAnnotate: false, pin: true)
}

enum CaptureOutput {
    /// Encodes, stores in history and runs the after-capture actions.
    /// `screenRect`: the captured area in CG (top-left) screen coordinates, when known.
    static func deliver(_ image: CGImage, scale: CGFloat, options: AfterCaptureOptions? = nil,
                        windowImage: CGImage? = nil, windowOnWallpaper: Bool = false, windowPadding: CGFloat = 0,
                        screenRect: CGRect? = nil) {
        let sourceApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.bundleIdentifier }
        // The raw window gets the same scale and colors, or the editor would open it at the wrong size.
        var windowScale = scale
        let windowImage = windowImage.map { ImageProcessing.applyOutputSettings($0, scale: &windowScale, border: false) }
        var scale = scale
        var processed = ImageProcessing.applyOutputSettings(image, scale: &scale)
        // Background preset from Screenshots settings (hold Shift to skip).
        let presetIndex = Defaults[Prefs.backgroundPreset], presets = BackgroundStyle.presets
        if presets.indices.contains(presetIndex), !NSEvent.modifierFlags.contains(.shift) {
            let size = CGSize(width: CGFloat(processed.width) / scale, height: CGFloat(processed.height) / scale)
            if let framed = AnnotationRenderer.export(base: processed, imageSize: size, effects: nil, annotations: [],
                                                      background: presets[presetIndex]) { processed = framed }
        }
        let format = Defaults[Prefs.fileFormat]
        let date = Date()
        guard let data = ImageEncoder.data(for: processed, format: format, scale: scale) else {
            CLIReply.error("couldn't encode the capture")
            glintLog("encoding failed (\(processed.width)x\(processed.height), bpc \(processed.bitsPerComponent), \(String(describing: processed.colorSpace?.name)))")
            NSSound.beep()
            return
        }
        var name = FileNaming.name(for: date)
        if Defaults[Prefs.askForName], let asked = FileNaming.askForName(defaultName: name) { name = asked }
        if Defaults[Prefs.add2xSuffix], scale > 1 { name += "@2x" }
        let url = HistoryStore.shared.newFileURL(name: name, ext: format.fileExtension, sourceApp: sourceApp)
        do { try data.write(to: url) } catch {
            glintLog("failed writing capture: \(error)")
            CLIReply.error("couldn't write the capture")
            NSSound.beep()
            return
        }
        let item = CaptureItem(image: processed, scale: scale, date: date, fileURL: url, kind: .screenshot)
        item.windowImage = windowImage
        item.windowOnWallpaper = windowOnWallpaper
        item.windowPadding = windowPadding
        item.screenRect = screenRect.map(Geometry.appKitRect(fromCG:))
        HistoryStore.shared.lastCapture = item
        SoundPlayer.playShutter()
        CLIReply.delivered(url)

        let opts = options ?? .fromSettings()
        glintLog("delivered \(url.lastPathComponent) quickAccess=\(opts.showQuickAccess)")
        if opts.copyToClipboard { Clipboard.copy(item) }
        if opts.save { _ = FileSaver.saveToExportLocation(item) }
        if opts.pin { PinManager.shared.pin(item) }
        if opts.openAnnotate, opts.showQuickAccess {
            // The card shows as "being edited", behind the editor.
            QuickAccessManager.shared.showEditing(item)
        } else if opts.openAnnotate {
            // The editor hands the capture to Quick Access when it closes.
            AnnotateWindowController.open(item: item)
        } else if opts.showQuickAccess {
            QuickAccessManager.shared.show(item)
        }
        SupportNote.captureDelivered()
    }
}

extension CaptureOutput {
    /// A finished recording (movie or GIF): into the history, then the recording after-capture actions.
    static func deliverRecording(_ file: URL, duration: Double, screenRect: CGRect?) {
        let sourceApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.bundleIdentifier }
        let date = Date()
        var name = FileNaming.name(for: date)
        if Defaults[Prefs.askForName], let asked = FileNaming.askForName(defaultName: name) { name = asked }
        let url = HistoryStore.shared.newFileURL(name: name, ext: file.pathExtension, sourceApp: sourceApp)
        do { try FileManager.default.moveItem(at: file, to: url) } catch {
            glintLog("failed storing recording: \(error)")
            CLIReply.error("couldn't store the recording")
            NSSound.beep()
            return
        }
        guard let item = CaptureItem.loadRecording(url, date: date) else { NSSound.beep(); return }
        if duration > 0 { item.duration = duration }
        HistoryStore.shared.lastCapture = item
        CLIReply.delivered(url)
        let opts = AfterCaptureOptions.fromSettings(.recording)
        glintLog("delivered recording \(url.lastPathComponent)")
        if opts.copyToClipboard { Clipboard.copy(item) }
        if opts.save { _ = FileSaver.saveToExportLocation(item) }
        if Defaults[Prefs.afterCapture(.openVideoEditor, .recording)] { VideoEditorWindowController.open(url: url) }
        if opts.showQuickAccess { QuickAccessManager.shared.show(item) }
        SupportNote.captureDelivered()
    }

    /// A Studio Mode recording: the video (without the cursor) goes into the history with its `Studio` folder next to
    /// it, and the video editor opens (its Save puts the finished video into Quick Access).
    static func deliverStudioRecording(_ file: URL, studio folder: URL, duration: Double) {
        let sourceApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0.bundleIdentifier }
        let date = Date()
        let url = HistoryStore.shared.newFileURL(name: FileNaming.name(for: date), ext: file.pathExtension, sourceApp: sourceApp)
        do {
            try FileManager.default.moveItem(at: file, to: url)
            try FileManager.default.moveItem(at: folder, to: StudioRecording.folder(for: url))
        } catch {
            glintLog("failed storing studio recording: \(error)")
            CLIReply.error("couldn't store the recording")
            NSSound.beep()
            return
        }
        if let item = CaptureItem.loadRecording(url, date: date) {
            if duration > 0 { item.duration = duration }
            HistoryStore.shared.lastCapture = item
        }
        glintLog("delivered studio recording \(url.lastPathComponent)")
        CLIReply.delivered(url)
        VideoEditorWindowController.open(url: url)
        SupportNote.captureDelivered()
    }
}

enum FileNaming {
    /// Expands the "File name format" template: {yyyy} {MM} {dd} {HH} {mm} {ss} are date fields.
    static func name(for date: Date, template: String = Defaults[Prefs.fileNameFormat]) -> String {
        var result = template
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let fields: [String: String] = [
            "{yyyy}": String(format: "%04d", c.year ?? 0), "{MM}": String(format: "%02d", c.month ?? 0),
            "{dd}": String(format: "%02d", c.day ?? 0), "{HH}": String(format: "%02d", c.hour ?? 0),
            "{mm}": String(format: "%02d", c.minute ?? 0), "{ss}": String(format: "%02d", c.second ?? 0),
        ]
        for (k, v) in fields { result = result.replacingOccurrences(of: k, with: v) }
        if let name = sanitized(result) { return name }
        return template == Prefs.fileNameFormat.defaultValue ? "Glint" : name(for: date, template: Prefs.fileNameFormat.defaultValue)
    }

    /// Something every format and volume can store as a file name; nil when nothing usable is left. A leading dot
    /// would hide the file from the history.
    private static func sanitized(_ name: String) -> String? {
        var result = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        result = String(result.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // File names are limited to 255 bytes; leave room for "@2x", " (1)" and the extension.
        while result.utf8.count > 200 { result.removeLast() }
        return result.isEmpty ? nil : result
    }

    static func askForName(defaultName: String) -> String? {
        NSApp.bringToFront()
        let alert = NSAlert()
        alert.messageText = "Name your capture"
        let field = NSTextField(string: defaultName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Use Default")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        // The extension comes from the format.
        var name = field.stringValue
        if ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "mp4", "mov"].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
        }
        return sanitized(name)
    }
}

enum Clipboard {
    static func copy(_ item: CaptureItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let entry = NSPasteboardItem()
        let mode = Defaults[Prefs.clipboardMode]
        // Recordings are copied as files (a GIF also as GIF data, so it pastes animated).
        if item.isRecording {
            entry.setString(item.fileURL.absoluteString, forType: .fileURL)
            if item.isGIF, let data = try? Data(contentsOf: item.fileURL) { entry.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif")) }
            pb.writeObjects([entry])
            return
        }
        if mode != .image { entry.setString(item.fileURL.absoluteString, forType: .fileURL) }
        if mode != .file {
            if let png = ImageEncoder.data(for: item.image, format: .png, scale: item.scale) { entry.setData(png, forType: .png) }
            if let tiff = item.nsImage.tiffRepresentation { entry.setData(tiff, forType: .tiff) }
        }
        pb.writeObjects([entry])
    }
}

enum FileSaver {
    static var exportDirectory: URL {
        let path = Defaults[Prefs.exportLocation]
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    @discardableResult
    static func saveToExportLocation(_ item: CaptureItem) -> URL? {
        save(item, to: exportDirectory)
    }

    static func saveWithPanel(_ item: CaptureItem) -> URL? {
        NSApp.bringToFront()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.fileURL.lastPathComponent
        panel.directoryURL = exportDirectory
        let source = ImageFormat(fileExtension: item.fileURL.pathExtension)
        // A screenshot can be saved in any image format; a recording is copied as it is, so its extension has to stay.
        let chooser = item.isRecording ? nil : source.map { SaveFormatChooser(panel: panel, format: $0) }
        if chooser == nil { panel.allowedContentTypes = UTType(filenameExtension: item.fileURL.pathExtension).map { [$0] } ?? [] }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let format = chooser?.format, format != source else { return copy(item.fileURL, to: url) }
        guard let data = ImageEncoder.data(for: item.image, format: format, scale: item.scale), (try? data.write(to: url)) != nil else {
            NSSound.beep()
            return nil
        }
        return url
    }

    static func save(_ item: CaptureItem, to directory: URL) -> URL? {
        let target = uniqueURL(directory.appendingPathComponent(item.fileURL.lastPathComponent))
        return copy(item.fileURL, to: target)
    }

    private static func copy(_ source: URL, to target: URL) -> URL? {
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch {
            glintLog("save failed: \(error)")
            NSSound.beep()
            return nil
        }
    }

    static func uniqueURL(_ url: URL) -> URL {
        var candidate = url
        var n = 1
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// The "Format" pop-up in an image's save panel. The file name's extension follows it.
final class SaveFormatChooser: NSObject {
    private(set) var format: ImageFormat
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(panel: NSSavePanel, format: ImageFormat) {
        self.format = format
        self.panel = panel
        super.init()
        popup.addItems(withTitles: ImageFormat.allCases.map(\.title))
        popup.selectItem(withTitle: format.title)
        popup.target = self
        popup.action = #selector(formatChanged)
        let row = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.setFrameSize(row.fittingSize)
        panel.accessoryView = row
        apply()
    }

    @objc private func formatChanged() {
        format = ImageFormat.allCases[popup.indexOfSelectedItem]
        apply()
    }

    private func apply() {
        guard let panel, let type = UTType(filenameExtension: format.fileExtension) else { return }
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = ((panel.nameFieldStringValue as NSString).deletingPathExtension as NSString).appendingPathExtension(format.fileExtension) ?? panel.nameFieldStringValue
    }
}

enum SoundPlayer {
    private static let systemDir = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
    private static var cache: [ShutterSound: NSSound] = [:]

    static func playShutter() {
        guard Defaults[Prefs.playSounds] else { return }
        play(Defaults[Prefs.shutterSound])
    }

    static func play(_ sound: ShutterSound) {
        if cache[sound] == nil {
            let path = switch sound {
            case .systemDefault: systemDir + "Screen Capture.aif"
            case .grab: systemDir + "Grab.aif"
            case .shutter: systemDir + "Shutter.aif"
            case .pop: "/System/Library/Sounds/Pop.aiff"
            case .tink: "/System/Library/Sounds/Tink.aiff"
            }
            cache[sound] = NSSound(contentsOfFile: path, byReference: true)
        }
        cache[sound]?.stop()
        cache[sound]?.play()
    }
}
