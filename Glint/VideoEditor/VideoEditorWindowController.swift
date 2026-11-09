import AppKit
import AVFoundation
import Combine
import SwiftUI

/// What the editor shows and where playback is (separate from the edit itself).
final class VideoEditorState: ObservableObject {
    enum Section: CaseIterable { case cursor, keystrokes, audio, captions, camera, background, animation }
    @Published var section: Section = .audio
    @Published var selectedZoom: UUID?
    /// The selected camera action (Studio Mode).
    @Published var selectedCamera: UUID?
    /// The selected action on the events track (`StudioEvent.id`).
    @Published var selectedEvent: String?
    /// The selected caption (timeline or transcript).
    @Published var selectedCaption: UUID?
    @Published var selectedClip: UUID?
    /// The cut tool. While it's on, the playhead stays where it is (cutting and clicking don't move it).
    @Published var scissors = false
    /// The selected cut marker (its output time); ⌫ removes the cut.
    @Published var selectedCut: Double?
    @Published var time: Double = 0
    @Published var isPlaying = false
    /// 0…1: the timeline's zoom slider (fit … 10× wider).
    @Published var timelineZoom: Double = 0
    /// The zoom slider is being dragged: the thumbnail strip stretches instead of re-laying out.
    @Published var timelineZoomEditing = false
    /// The slider position where the whole video fits (set by the timeline).
    @Published var timelineFitZoom: Double = 0
    /// The timeline's frames are the recording's own (no zooms, cursor, camera…) instead of the edited video's.
    @Published var rawFrames = Defaults[Prefs.editorRawFrames] { didSet { Defaults[Prefs.editorRawFrames] = rawFrames } }
}

/// The video editor: a 1180×858 window with the file name in the middle of a 52pt
/// bar (Share + Export on the right), an icon rail and inspector on the left, the preview with transport controls,
/// and a timeline with a zoom track and the clip's thumbnails underneath.
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [VideoEditorWindowController] = []
    static var hasOpenEditors: Bool { !open.isEmpty }

    let project: VideoProject
    let state = VideoEditorState()
    let player = AVPlayer()
    private var renderer: VideoFrameRenderer?
    private var structureKey = ""
    private var renderKey = ""
    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var keyMonitor: Any?
    private var observers: [Any] = []
    private lazy var timeline = VideoTimelineView(project: project, state: state)

    static let base = Color(red: 0x21 / 255.0, green: 0x21 / 255.0, blue: 0x21 / 255.0)
    static let dark = Color(red: 0x17 / 255.0, green: 0x17 / 255.0, blue: 0x17 / 255.0)
    static let box = Color(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2A / 255.0)
    static let line = Color(red: 0x30 / 255.0, green: 0x30 / 255.0, blue: 0x30 / 255.0)
    static let blue = Color(.displayP3, red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)

    /// Called when the window closes (Quick Access brings the card back, refreshed if the file was saved).
    var onClose: (() -> Void)?

    /// Opens a recording (or any movie) in the editor.
    /// `opened`: called with the editor's window once it's on screen (New Tab puts it in the chooser's place).
    static func open(url: URL, onClose: (() -> Void)? = nil, opened: ((NSWindow) -> Void)? = nil) {
        // GIFs get the GIF editor: trimming only.
        if url.pathExtension.lowercased() == "gif" { GIFTrimmer.open(url: url, onClose: onClose); return }
        if let existing = open.first(where: { $0.sourceFile == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if let window = existing.window { opened?(window) }
            return
        }
        Task {
            // GIFs are edited as a temporary movie and turned back into a GIF on Save/Export.
            var movie = url
            if url.pathExtension.lowercased() == "gif" {
                guard let converted = await GIFMovie.movie(from: url) else { NSSound.beep(); return }
                movie = converted
            }
            // A video saved from the editor keeps its original and the edit next to it ("Edit" folder), so it can be
            // re-edited with all settings instead of editing the rendered result.
            let saved = SavedEdit.load(for: url)
            if saved != nil, FileManager.default.fileExists(atPath: SavedEdit.original(for: url).path) { movie = SavedEdit.original(for: url) }
            let project = VideoProject(url: movie)
            do { try await project.load() } catch {
                glintLog("video editor: can't open \(url.lastPathComponent): \(error)")
                NSSound.beep()
                return
            }
            // Studio Mode: the pointer, keys and camera recorded next to the video.
            if let studio = StudioRecording.load(for: url) { project.attachStudio(studio, folder: StudioRecording.folder(for: url)) }
            // The settings apply to the original when Save kept one, else to the file itself (a closed project).
            if let saved { project.restoreSaved(saved) } else if project.isStudio { project.applyStudioDefaults() }
            let controller = VideoEditorWindowController(project: project, sourceFile: url)
            controller.onClose = onClose
            open.append(controller)
            NSApp.setActivationPolicy(Defaults[Prefs.annotateShowDockIcon] ? .regular : .accessory)
            NSApp.activate()
            controller.window?.center()
            controller.showWindow(nil)
            if let window = controller.window { opened?(window) }
            // Opened by itself (a Studio recording stopped, seconds after the click), Glint may not be let in front
            // right away: the window goes on top regardless, and asks again once the Dock icon is there.
            controller.window?.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.activate()
                controller.window?.makeKeyAndOrderFront(nil)
            }
            controller.rebuild(force: true)
            // A Studio Mode recording opens on the cursor settings.
            if project.isStudio { controller.state.section = .cursor }
        }
    }

    static func openFromPanel() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    /// The file the editor saves into (the GIF itself for the GIF editor).
    let sourceFile: URL
    private var saving = false
    var isGIF: Bool { sourceFile.pathExtension.lowercased() == "gif" }

    private init(project: VideoProject, sourceFile: URL) {
        self.project = project
        self.sourceFile = sourceFile
        player.appliesMediaSelectionCriteriaAutomatically = false  // no subtitles of the player's own
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 858),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        EditorHeadBar.configure(window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 960, height: VideoEditorContent.minWindowHeight)
        window.title = sourceFile.lastPathComponent
        window.collectionBehavior.insert(.moveToActiveSpace)
        EditorTabbing.configure(window)
        super.init(window: window)
        window.delegate = self
        // Clicking the timeline jumps there and pauses.
        timeline.onPause = { [weak self] in
            guard let self, self.state.isPlaying || self.player.rate != 0 else { return }
            self.player.pause()
            self.state.isPlaying = false
        }
        timeline.onHoverFrame = { [weak self] hover in self?.showHoverPreview(hover) }
        timeline.onSeek = { [weak self] t in
            guard let self else { return }
            self.timeline.onPause?()
            self.seek(t)
        }
        buildContent()
        observePlayback()
        observeEdits()
        installKeys()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0x21 / 255.0, alpha: 1).cgColor
        // The title bar's band, then the head bar (under any tabs) with Share, Save and Export on the right.
        let band = EditorHeadBar.titleBand()
        let buttons = NSHostingView(rootView: HStack(spacing: 8) {
            HeadShareButton(help: "Share the edited video") { [weak self] anchor in self?.share(from: anchor) }
            Button("Save") { [weak self] in self?.save() }
                .buttonStyle(BarTextButtonStyle(prominent: false)).help("Save the edits into this recording (Quick Access and History)")
            Button("Export") { [weak self] in self?.showExport() }
                .buttonStyle(BarTextButtonStyle(prominent: true)).help("Export the edited video")
        }.fixedSize())
        buttons.sizingOptions = [.intrinsicContentSize]
        let head = EditorHeadBar(trailing: buttons)
        let editor = NSHostingView(rootView: VideoEditorContent(project: project, state: state, player: player, timeline: timeline,
                                                                actions: actions))
        editor.sizingOptions = []
        editor.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editor)
        content.addSubview(band)
        content.addSubview(head)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: content.topAnchor),
            band.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            band.bottomAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            head.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            head.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.topAnchor.constraint(equalTo: head.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    private var actions: VideoEditorActions {
        VideoEditorActions(
            togglePlay: { [weak self] in self?.togglePlay() },
            seek: { [weak self] t in self?.seek(t) },
            toStart: { [weak self] in self?.seek(0, reveal: true) },
            toEnd: { [weak self] in self.map { $0.seek($0.project.duration, reveal: true) } },
            frame: { [weak self] t in self?.frame(at: t) },
            toggleFullScreen: { [weak self] in self?.window?.toggleFullScreen(nil) },
            everyFrame: { [weak self] in self?.toggleEveryFrame() },
            beginScrub: { [weak self] in self?.beginScrub($0) },
            endScrub: { [weak self] in self?.endScrub() }
        )
    }

    /// One thumbnail per video frame, around the playhead; again: the whole video fits.
    private func toggleEveryFrame() {
        state.timelineZoom = state.timelineZoom > 0.999 ? state.timelineFitZoom : 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.timeline.reveal(self.state.time)
        }
    }

    // MARK: Playback

    private func observePlayback() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.player.rate != 0 || self.state.isPlaying else { return }
                self.state.time = min(time.seconds, self.project.duration)
            }
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.state.isPlaying = false
                self.state.time = self.project.duration
            }
        })
    }

    func togglePlay() {
        hoverPreview.isHidden = true
        if state.isPlaying {
            player.pause()
            state.isPlaying = false
        } else {
            if state.time >= project.duration - 0.05 { seek(0) }
            player.play()
            state.isPlaying = true
        }
    }

    /// `reveal`: scroll the timeline so the playhead is in view (Go to Start/End, arrow keys).
    func seek(_ t: Double, reveal: Bool = false) {
        let t = min(max(t, 0), project.duration)
        state.time = t
        if reveal { timeline.reveal(t) }
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// A still of the edited timeline at `t` (for the zoom inspector's mini preview).
    private func frame(at t: Double) -> CGImage? { timeline.thumbnail(at: t) }

    // MARK: Rebuilding the preview

    private func observeEdits() {
        observers.append(project.$revision.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild(force: false) }
        })
        observers.append(project.$isEdited.sink { [weak self] edited in self?.window?.isDocumentEdited = edited })
    }

    /// Clips or the canvas size changed: a new player item. A look change (zoom, background…) only updates the
    /// renderer and redraws the frame; a volume change only swaps the audio mix, so the picture doesn't flicker.
    func rebuild(force: Bool) {
        // The preview is the video with its zooms only, at most ~1600px wide (the export uses full size and bakes
        // the background in). Background, padding, corners and shadow are layers in the editor (instant).
        let source = project.sourceSize
        let previewScale = min(1, 1600 / max(source.width, 1))
        let settings = project.renderSettings(outputScale: previewScale, includeBackground: false)
        let renderSize = CGSize(width: (source.width * previewScale / 2).rounded() * 2, height: (source.height * previewScale / 2).rounded() * 2)
        let key = "\(project.clips.map { "\($0.start)-\($0.end)" })"
        let look = "\(project.zooms)|\(project.zoomAnimation)|\(project.motionBlur)|\(project.edit.cursor)|\(project.edit.keystrokes)|\(project.edit.camera)|\(project.cameraLayouts)|\(project.edit.removedEvents)|\(project.edit.captions.hashValue)|\(project.edit.captionStyle)|\(project.edit.showCaptions)"
        if !force, key == structureKey, let renderer, let item = player.currentItem, let composition = item.videoComposition {
            if look != renderKey {
                renderKey = look
                renderer.update(settings)
                thumbnailRenderer?.update(thumbnailSettings())
                timeline.editedLookChanged()
                item.videoComposition = composition.copy() as? AVVideoComposition
                // A paused player doesn't redraw for a new composition: nudge it to the same moment again.
                if !state.isPlaying { refreshPausedFrame() }
            }
            updateAudio(of: item)
            timeline.refresh()
            return
        }
        structureKey = key
        renderKey = look
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (composition, mix) = try await project.makeComposition()
                let renderer = self.renderer ?? VideoFrameRenderer(settings)
                renderer.update(settings)
                self.renderer = renderer
                let videoComposition = try await VideoFrameRenderer.videoComposition(for: composition, renderer: renderer,
                                                                                     renderSize: renderSize, frameRate: project.frameRate)
                // The timeline's edited frames: the same video, rendered small.
                let thumbnails = self.thumbnailRenderer ?? VideoFrameRenderer(thumbnailSettings())
                thumbnails.update(thumbnailSettings())
                self.thumbnailRenderer = thumbnails
                let thumbnailComposition = try await VideoFrameRenderer.videoComposition(for: composition, renderer: thumbnails,
                                                                                         renderSize: thumbnailSize, frameRate: project.frameRate)
                guard !Task.isCancelled else { return }
                editedFrames = (composition, thumbnailComposition)
                timeline.setEditedSource(asset: composition, composition: thumbnailComposition)
                let item = AVPlayerItem(asset: composition)
                item.hideSystemSubtitles()
                item.videoComposition = videoComposition
                item.audioMix = mix
                let wasPlaying = state.isPlaying
                player.replaceCurrentItem(with: item)
                seek(min(state.time, project.duration))
                if wasPlaying { player.play() }
                timeline.refresh()
            } catch {
                glintLog("video editor: rebuild failed: \(error)")
            }
        }
    }

    // MARK: Edited frames (timeline and its hover preview)

    private var thumbnailRenderer: VideoFrameRenderer?
    private var editedFrames: (asset: AVAsset, composition: AVVideoComposition)?
    /// 480px wide: sharp in the 240pt hover preview, and plenty for the timeline's tiles.
    private var thumbnailScale: CGFloat { min(1, 480 / max(project.sourceSize.width, 1)) }
    private var thumbnailSize: CGSize {
        let s = project.sourceSize
        return CGSize(width: max((s.width * thumbnailScale / 2).rounded() * 2, 2), height: max((s.height * thumbnailScale / 2).rounded() * 2, 2))
    }
    private func thumbnailSettings() -> VideoRenderSettings {
        project.renderSettings(outputScale: thumbnailScale, includeBackground: false, includeCaptions: false)
    }

    /// The edited video's frame at output time `t`.
    private func editedStill(at t: Double, maxSize: CGSize) async -> CGImage? {
        guard let editedFrames else { return nil }
        let generator = AVAssetImageGenerator(asset: editedFrames.asset)
        generator.videoComposition = editedFrames.composition
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        return try? await generator.image(at: CMTime(seconds: min(t, max(project.duration - 0.03, 0)), preferredTimescale: 600)).image
    }

    private func refreshPausedFrame() {
        let t = player.currentTime()
        let nudge = CMTime(value: 1, timescale: 600)
        player.seek(to: t + nudge > (player.currentItem?.duration ?? t) ? t - nudge : t + nudge, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated { self?.player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) }
        }
    }

    private func updateAudio(of item: AVPlayerItem) {
        let project = project
        Task {
            guard let tracks = try? await item.asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return }
            item.audioMix = project.audioMix(for: tracks)
        }
    }

    // MARK: Keys

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .keyUp {
                guard event.keyCode == 123 || event.keyCode == 124, self.scrubTimer != nil else { return event }
                self.endScrub()
                return nil
            }
            guard !(self.window?.firstResponder is NSText) else { return event }
            // ⌘Z / ⇧⌘Z undo and redo any edit (by the character, so it works on QWERTZ too).
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" {
                self.save()
                return nil
            }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
                if event.modifierFlags.contains(.shift) { self.project.redo() } else { self.project.undo() }
                return nil
            }
            switch event.keyCode {
            case 49: self.togglePlay(); return nil  // Space
            case 53 where self.state.scissors: self.state.scissors = false; return nil  // Esc leaves the cut tool
            case 8 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:  // C toggles it
                self.state.scissors.toggle(); return nil
            case 51, 117: self.deleteSelection(); return nil  // ⌫ / ⌦
            case 40 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:  // K pauses
                if self.state.isPlaying { self.togglePlay() }
                return nil
            case 123, 124: self.arrowKey(forward: event.keyCode == 124, event: event); return nil
            case 115: self.seek(0, reveal: true); return nil  // Home
            case 119: self.seek(self.project.duration, reveal: true); return nil  // End
            default: return event
            }
        }
    }

    /// ←/→ move through the video and speed up while held; ⌥←/→ step one frame; ⌘←/→ go to the start or end.
    private func arrowKey(forward: Bool, event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) {
            if !event.isARepeat { seek(forward ? project.duration : 0, reveal: true) }
        } else if flags.contains(.option) {
            seek(state.time + (forward ? 1 : -1) / project.frameRate, reveal: true)
        } else if !event.isARepeat {
            beginScrub(forward ? 1 : -1)
        }
    }

    // MARK: Scrubbing

    /// A tap moves this far (seconds): a small, precise nudge.
    private static let scrubTap = 0.1
    /// Held longer than this, it starts moving by itself, at this speed (video seconds per second)…
    private static let scrubHoldDelay = 0.2
    private static let scrubStartSpeed = 1.5
    /// …which grows by this factor every second, up to crossing a third of the video per second.
    private static let scrubGrowth = 2.6

    private var scrubTimer: Timer?
    private var scrubDirection = 1.0
    private var scrubStart: TimeInterval = 0
    private var scrubLast: TimeInterval = 0
    private var scrubTarget: Double?
    private var scrubSeeking = false

    private func beginScrub(_ direction: Double) {
        scrubTimer?.invalidate()
        if state.isPlaying { togglePlay() }
        hoverPreview.isHidden = true
        scrubDirection = direction
        scrubStart = ProcessInfo.processInfo.systemUptime
        scrubLast = scrubStart
        moveScrub(by: direction * Self.scrubTap)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrubTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrubTimer = timer
    }

    private func scrubTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let held = now - scrubStart - Self.scrubHoldDelay
        defer { scrubLast = now }
        guard held > 0 else { return }
        let limit = max(project.duration / 3, Self.scrubStartSpeed)
        let speed = min(Self.scrubStartSpeed * pow(Self.scrubGrowth, held), limit)
        moveScrub(by: scrubDirection * speed * (now - scrubLast))
    }

    private func moveScrub(by seconds: Double) {
        let t = min(max(state.time + seconds, 0), project.duration)
        state.time = t
        timeline.follow(t)
        seekWhileScrubbing(t)
    }

    /// One seek at a time, not exact (exact ones can't keep up); when it lands, the next goes to where the playhead is by then.
    private func seekWhileScrubbing(_ t: Double) {
        scrubTarget = t
        guard !scrubSeeking else { return }
        scrubSeeking = true
        let tolerance = CMTime(value: 1, timescale: 10)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scrubSeeking = false
                if let target = self.scrubTarget, target != t { self.seekWhileScrubbing(target) }
            }
        }
    }

    /// Key or button released: the playhead lands exactly.
    private func endScrub() {
        guard scrubTimer != nil else { return }
        scrubTimer?.invalidate()
        scrubTimer = nil
        scrubTarget = nil
        seek(state.time)
    }

    func windowDidResignKey(_ notification: Notification) { endScrub() }

    private func deleteSelection() {
        if let at = state.selectedCut {
            state.selectedCut = nil
            project.restoreCut(at: at)
        } else if let id = state.selectedEvent {
            state.selectedEvent = nil
            project.edit.removedEvents.append(id)
        } else if let id = state.selectedCamera {
            state.selectedCamera = nil
            project.cameraLayouts.removeAll { $0.id == id }
        } else if let id = state.selectedZoom {
            state.selectedZoom = nil
            project.zooms.removeAll { $0.id == id }
        } else if let id = state.selectedClip {
            project.deleteClip(id)
            state.selectedClip = nil
        }
    }

    #if DEBUG
    /// What `glint://debug-state` logs for the frontmost editor.
    var debugState: String { "video time=\(state.time) playing=\(state.isPlaying) timelineX=\(timeline.scrollView.contentView.bounds.minX) zoom=\(state.timelineZoom) fit=\(state.timelineFitZoom)" }
    #endif

    // MARK: Timeline hover preview

    private lazy var hoverPreview = TimelineHoverPreview()

    private func showHoverPreview(_ hover: VideoTimelineView.HoverFrame?) {
        guard let content = window?.contentView else { return }
        guard let hover, let frame = hover.frame else { hoverPreview.isHidden = true; return }
        if hoverPreview.superview == nil { content.addSubview(hoverPreview) }
        let width: CGFloat = 240
        let aspect = project.renderSize.height / max(project.renderSize.width, 1)
        let size = CGSize(width: width, height: (width * aspect).rounded() + TimelineHoverPreview.labelHeight)
        let x = min(max(hover.x - size.width / 2, 8), content.bounds.width - size.width - 8)
        hoverPreview.frame = CGRect(x: x, y: hover.top + 8, width: size.width, height: size.height)
        let seconds = Int(max(hover.time, 0))
        let label = String(format: "%02d:%02d", seconds / 60, seconds % 60)
        // The strip's tile shows at once; the exact frame (sharp, at the preview's pixel size) replaces it.
        if hoverSharpTime.map({ abs($0 - hover.time) > 0.02 }) ?? true { hoverPreview.show(frame, time: label) }
        hoverSharpTask?.cancel()
        let t = hover.time, pixels = CGSize(width: size.width * 2, height: (size.height - TimelineHoverPreview.labelHeight) * 2)
        let raw = state.rawFrames
        hoverSharpTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self,
                  let sharp = raw ? await self.project.still(at: t, maxSize: pixels) : await self.editedStill(at: t, maxSize: pixels),
                  !Task.isCancelled, !self.hoverPreview.isHidden else { return }
            self.hoverSharpTime = t
            self.hoverPreview.show(sharp, time: label)
        }
    }

    private var hoverSharpTask: Task<Void, Never>?
    private var hoverSharpTime: Double?

    // MARK: Export

    private func showExport() {
        guard let window else { return }
        player.pause()
        state.isPlaying = false
        VideoExportSheet.present(on: window, project: project) { [weak self] url, replace in
            guard let self, let url else { return }
            Task {
                guard let file = await self.finalFile(url) else { NSSound.beep(); return }
                if replace { self.replaceSource(with: file); return }
                CaptureOutput.deliverRecording(file, duration: self.project.duration, screenRect: nil)
                self.project.markExported()
            }
        }
    }

    /// The exported movie, or the GIF made from it in the GIF editor.
    private func finalFile(_ movie: URL) async -> URL? {
        guard isGIF, movie.pathExtension.lowercased() != "gif" else { return movie }
        let gif = movie.deletingPathExtension().appendingPathExtension("gif")
        return await GIFEncoder.encode(movie: movie, to: gif) ? gif : nil
    }

    /// Save: the edit replaces the recording's file, so the Quick Access card and the history show the edited
    /// version; the editor closes (editing is done).
    func save() {
        guard !saving else { return }
        saving = true
        player.pause()
        state.isPlaying = false
        let project = project, target = sourceFile
        let progress = window.map { SavingSheet.show(on: $0) }
        Task {
            defer {
                saving = false
                if let progress, let window { window.endSheet(progress) }
            }
            guard let movie = try? await VideoExporter.export(project: project, scale: 1, quality: 3, includeAudio: project.includeAudio, progress: { _ in }),
                  let file = await finalFile(movie) else { NSSound.beep(); return }
            replaceSource(with: file)
        }
    }

    /// Save and "Replace Video": the render replaces the recording; the unedited original and the settings are kept
    /// (`SavedEdit`) so it stays re-editable. Then the editor closes.
    private func replaceSource(with file: URL) {
        let target = sourceFile
        let original = SavedEdit.original(for: target)
        if !FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: target, to: original)
        }
        SavedEdit.store(project.edit, for: target)
        do { _ = try FileManager.default.replaceItemAt(target, withItemAt: file) } catch {
            glintLog("video editor: save failed: \(error)")
            NSSound.beep()
            return
        }
        project.markExported()
        let fromQuickAccess = onClose != nil
        window?.close()
        if !fromQuickAccess, let item = CaptureItem.loadRecording(target, date: Date()) { QuickAccessManager.shared.show(item) }
    }

    private func share(from anchor: NSView) {
        player.pause()
        state.isPlaying = false
        Task {
            guard let movie = try? await VideoExporter.export(project: project, scale: 1, quality: 2, includeAudio: true, progress: { _ in }),
                  let url = await finalFile(movie) else {
                NSSound.beep()
                return
            }
            NSSharingServicePicker(items: [url]).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard project.isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save your changes before closing?"
        alert.informativeText = "Save updates this recording in Quick Access and the history. Export… creates a new file. Close Project keeps your edits, so they're back the next time you open this recording."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Close Project")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self?.save()
                case .alertSecondButtonReturn: self?.showExport()
                case .alertThirdButtonReturn:
                    // The edit is kept as a project: the recording stays as it is, the settings come back on reopening.
                    if let self, !self.isGIF { SavedEdit.store(self.project.edit, for: self.sourceFile) }
                    self?.project.markExported()
                    sender.close()
                default: break
                }
            }
        }
        return false
    }

    /// New Tab (⌘T, or + in the tab bar).
    override func newWindowForTab(_ sender: Any?) { EditorTabbing.newTab(from: window) }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        Self.open.removeAll { $0 === self }
        onClose?()
        onClose = nil
        if Self.open.isEmpty, !AnnotateWindowController.hasOpenEditors { NSApp.setActivationPolicy(.accessory) }
    }
}

/// The frame under the pointer, floating above the timeline: the picture in the editor's box style (#2A2A2A,
/// #303030 line, 8pt corners) with the time below it.
final class TimelineHoverPreview: NSView {
    static let labelHeight: CGFloat = 22
    private let image = CALayer()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0x2A / 255.0, alpha: 1).cgColor
        layer?.borderColor = NSColor(white: 0x30 / 255.0, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        shadow = NSShadow()
        image.contentsGravity = .resizeAspect
        layer?.addSublayer(image)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.85)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ frame: CGImage, time: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image.contents = frame
        image.frame = CGRect(x: 0, y: Self.labelHeight, width: bounds.width, height: bounds.height - Self.labelHeight)
        CATransaction.commit()
        label.stringValue = time
        label.frame = CGRect(x: 0, y: 3, width: bounds.width, height: 16)
        if isHidden { isHidden = false }
    }
}

/// "Saving…" with a spinner while Save renders the video.
enum SavingSheet {
    static func show(on window: NSWindow) -> NSWindow {
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
        let spinner = NSProgressIndicator(frame: CGRect(x: 24, y: 23, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Saving…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = CGRect(x: 60, y: 25, width: 160, height: 20)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 70))
        content.addSubview(spinner)
        content.addSubview(label)
        sheet.contentView = content
        window.beginSheet(sheet)
        return sheet
    }
}

/// A saved edit: `<capture folder>/Edit/<file name>` (the unedited original) and `Edit/edit.json` (the settings).
enum SavedEdit {
    static func original(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("Edit").appendingPathComponent(url.lastPathComponent)
    }

    private static func settings(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("Edit").appendingPathComponent("edit.json")
    }

    static func load(for url: URL) -> VideoEdit? {
        guard let data = try? Data(contentsOf: settings(for: url)) else { return nil }
        return try? JSONDecoder().decode(VideoEdit.self, from: data)
    }

    static func store(_ edit: VideoEdit, for url: URL) {
        try? FileManager.default.createDirectory(at: settings(for: url).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(edit).write(to: settings(for: url))
    }
}
