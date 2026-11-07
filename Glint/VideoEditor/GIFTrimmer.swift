import AppKit
import AVFoundation
import AVKit

/// The GIF editor: trimming only. A plain window shows the GIF with the
/// standard macOS trim bar under it (play button, yellow trim handles, Trim / Cancel). Trim rewrites the GIF in
/// place (Quick Access and the history show the trimmed version); Cancel closes.
final class GIFTrimmer: NSWindowController, NSWindowDelegate {
    private static var open: [GIFTrimmer] = []
    static var hasOpenEditors: Bool { !open.isEmpty }

    let sourceFile: URL
    private let playerView = AVPlayerView()
    private var onClose: (() -> Void)?
    private var busy = false

    static func open(url: URL, onClose: (() -> Void)? = nil) {
        if let existing = open.first(where: { $0.sourceFile == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        Task {
            guard let movie = await GIFMovie.movie(from: url) else { NSSound.beep(); onClose?(); return }
            let asset = AVURLAsset(url: movie)
            let size = (try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)) ?? CGSize(width: 800, height: 600)
            let controller = GIFTrimmer(source: url, movie: movie, pixelSize: size)
            controller.onClose = onClose
            open.append(controller)
            NSApp.activate()
            controller.window?.center()
            controller.showWindow(nil)
            controller.beginTrimming()
        }
    }

    private init(source: URL, movie: URL, pixelSize: CGSize) {
        sourceFile = source
        // The GIF is shown one point per pixel (800 px → 800 pt) with the trim bar below (~90 pt).
        let width = min(max(pixelSize.width, 480), 1000)
        let height = min(width * pixelSize.height / max(pixelSize.width, 1), 760)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height + 90),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = source.lastPathComponent
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        super.init(window: window)
        window.delegate = self
        playerView.player = AVPlayer(url: movie)
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        playerView.frame = window.contentView?.bounds ?? .zero
        playerView.autoresizingMask = [.width, .height]
        window.contentView = playerView
    }

    required init?(coder: NSCoder) { fatalError() }

    private func beginTrimming() {
        // The trim bar appears once the player item is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.playerView.canBeginTrimming else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.beginTrimming() }
                return
            }
            self.playerView.beginTrimming { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if result == .okButton { self.trim() } else { self.window?.close() }
                }
            }
        }
    }

    private func trim() {
        guard !busy, let item = playerView.player?.currentItem, let movie = (item.asset as? AVURLAsset)?.url else { return }
        busy = true
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        let target = sourceFile
        Task {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("glint-trim-\(UUID().uuidString).gif")
            guard await GIFEncoder.encode(movie: movie, to: output, range: CMTimeRange(start: start, end: end)) else {
                NSSound.beep()
                busy = false
                return
            }
            do { _ = try FileManager.default.replaceItemAt(target, withItemAt: output) } catch {
                glintLog("gif trim: save failed: \(error)")
                NSSound.beep()
                busy = false
                return
            }
            let fromQuickAccess = onClose != nil
            window?.close()
            if !fromQuickAccess, let item = CaptureItem.loadRecording(target, date: Date()) { QuickAccessManager.shared.show(item) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.open.removeAll { $0 === self }
        onClose?()
        onClose = nil
    }
}
