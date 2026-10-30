import AppKit
import AVFoundation
import CoreImage

/// A piece of the source video that stays in (source seconds). Trimming and the scissors edit these.
struct VideoClip: Equatable, Identifiable, Codable {
    var id = UUID()
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

/// A zoom on the output timeline (seconds): it eases in, holds `scale` around `center` (0…1, top-left origin) and
/// eases out again before `end`.
struct VideoZoom: Equatable, Identifiable, Codable {
    let id = UUID()
    var start: Double
    var end: Double
    var scale: Double = 1.5
    var center = CGPoint(x: 0.5, y: 0.5)
}

/// The Background section: the screenshot editor's fills around the video, with padding, shadow and corners.
struct VideoBackground: Equatable, Codable {
    var fill: BackgroundStyle.Fill = .gradient(0)
    /// 0…1 = 0…25% of the video's shorter side on every side.
    var padding: Double = 0
    var shadow: Double = 0
    /// 0…1 = 0…50% of the shorter side (fully round at the end, like the screenshot editor's Corners).
    var corners: Double = 0
    static let maxCornerFraction = 0.5
    var ratio: BackgroundStyle.Ratio = .auto

    var isVisible: Bool { padding > 0 || ratio != .auto }
}

enum ZoomAnimation: String, Codable { case smooth, dynamic }

/// Every setting of an edit in one value. Undo/redo snapshot this whole value, so any setting added here later is
/// undoable automatically, and a change touching several things at once ("Apply to All") is one step.
struct VideoEdit: Equatable, Codable {
    var clips: [VideoClip] = []
    var zooms: [VideoZoom] = []
    var background = VideoBackground()
    var zoomAnimation: ZoomAnimation = .smooth
    /// Off, Low, Medium, High.
    var motionBlur = 2
    /// 0…2 (100% in the middle of the slider).
    var volume: Double = 1
    /// "Include audio": off plays and exports the video silent.
    var includeAudio = true
}

/// One editing session: the source movie and every edit, from which the preview and the export are built.
final class VideoProject: ObservableObject {
    let url: URL
    let asset: AVURLAsset
    private(set) var sourceDuration: Double = 0
    private(set) var sourceSize: CGSize = .zero
    private(set) var frameRate: Double = 30
    private(set) var hasAudio = false

    @Published var edit = VideoEdit() { didSet { if edit != oldValue { changed() } } }
    var clips: [VideoClip] { get { edit.clips } set { edit.clips = newValue } }
    var zooms: [VideoZoom] { get { edit.zooms } set { edit.zooms = newValue } }
    var background: VideoBackground { get { edit.background } set { edit.background = newValue } }
    var zoomAnimation: ZoomAnimation { get { edit.zoomAnimation } set { edit.zoomAnimation = newValue } }
    var motionBlur: Int { get { edit.motionBlur } set { edit.motionBlur = newValue } }
    var volume: Double { get { edit.volume } set { edit.volume = newValue } }
    var includeAudio: Bool { get { edit.includeAudio } set { edit.includeAudio = newValue } }

    // Undo: snapshots of `edit`. Changes within 0.4 s (a slider drag, several fields at once) become one step.
    private var undoStack: [VideoEdit] = []
    private var redoStack: [VideoEdit] = []
    private var committed = VideoEdit()
    private var commitWork: DispatchWorkItem?
    private var restoring = false
    var canUndo: Bool { !undoStack.isEmpty || edit != committed }
    var canRedo: Bool { !redoStack.isEmpty }
    @Published private(set) var isEdited = false
    /// Bumped on every edit; the editor rebuilds the preview from it.
    @Published private(set) var revision = 0
    private var loaded = false

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    /// A sharp still of the edited timeline at `t` (for the zoom position picker).
    func still(at t: Double, maxSize: CGSize) async -> CGImage? {
        guard let source = locate(t)?.source else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        return try? await generator.image(at: CMTime(seconds: source, preferredTimescale: 600)).image
    }

    /// A saved edit reopened: its settings come back (undo starts from here).
    func restoreSaved(_ saved: VideoEdit) {
        edit = saved
        committed = saved
        isEdited = false
    }

    /// The edits are safely exported (or the user chose to drop them).
    func markExported() { isEdited = false }

    private func changed() {
        guard loaded else { return }
        isEdited = true
        revision += 1
        guard !restoring else { return }
        commitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commit() }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func commit() {
        commitWork?.cancel()
        commitWork = nil
        guard edit != committed else { return }
        undoStack.append(committed)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        committed = edit
    }

    func undo() {
        commit()
        guard let previous = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(edit)
        restore(previous)
    }

    func redo() {
        commit()
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(edit)
        restore(next)
    }

    private func restore(_ state: VideoEdit) {
        restoring = true
        edit = state
        committed = state
        restoring = false
    }

    func load() async throws {
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (natural, transform, rate, minFrame) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration)
        let size = natural.applying(transform)
        sourceSize = CGSize(width: abs(size.width), height: abs(size.height))
        // Screen recordings have a variable frame rate (a tiny nominal rate): use the shortest frame interval.
        let fastest = minFrame.isValid && minFrame.seconds > 0 ? 1 / minFrame.seconds : 0
        frameRate = min(max(Double(rate), fastest, 10), 120)
        hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        sourceDuration = duration
        clips = [VideoClip(start: 0, end: duration)]
        committed = edit
        loaded = true
    }

    /// The edited length (the clips one after another).
    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    /// Where each clip starts on the output timeline.
    var clipStarts: [Double] {
        var t = 0.0
        return clips.map { clip in defer { t += clip.duration }; return t }
    }

    /// The cut markers: removed stretches ("✂ 0.8s": before the first clip, between clips, after the last) and plain
    /// splits between two clips that still touch (length 0, just the scissors).
    var cuts: [(at: Double, length: Double)] {
        guard let first = clips.first, let last = clips.last else { return [] }
        var result: [(Double, Double)] = []
        if first.start > 0.05 { result.append((0, first.start)) }
        let starts = clipStarts
        for i in 1..<max(clips.count, 1) {
            let gap = clips[i].start - clips[i - 1].end
            result.append((starts[i], gap > 0.05 ? gap : 0))
        }
        if sourceDuration - last.end > 0.05 { result.append((duration, sourceDuration - last.end)) }
        return result
    }

    /// The clip under an output time and the matching source time.
    func locate(_ t: Double) -> (index: Int, source: Double)? {
        let starts = clipStarts
        for (i, clip) in clips.enumerated() where t <= starts[i] + clip.duration || i == clips.count - 1 {
            return (i, clip.start + min(max(t - starts[i], 0), clip.duration))
        }
        return nil
    }

    // MARK: Edits

    /// The scissors: splits the clip under `t` in two.
    func split(at t: Double) {
        guard let (i, source) = locate(t), source - clips[i].start > 0.1, clips[i].end - source > 0.1 else { return }
        let clip = clips[i]
        clips.replaceSubrange(i...i, with: [VideoClip(start: clip.start, end: source), VideoClip(start: source, end: clip.end)])
    }

    /// The scissors dragged over a stretch: cuts output time `a…b` out in one step (at least 0.1 s stays). Zooms after
    /// the cut move left with the video; ones inside it shrink or go.
    func removeRange(_ a: Double, _ b: Double) {
        let a = max(min(a, b), 0), b = min(max(a, b), duration)
        guard b - a > 0.05, duration - (b - a) > 0.1 else { return }
        var kept: [VideoClip] = []
        for (clip, start) in zip(clips, clipStarts) {
            let end = start + clip.duration
            if start < a { kept.append(VideoClip(id: clip.id, start: clip.start, end: clip.start + min(end, a) - start)) }
            if end > b {
                let piece = VideoClip(start: clip.start + max(start, b) - start, end: clip.end)
                kept.append(start < a ? piece : VideoClip(id: clip.id, start: piece.start, end: piece.end))
            }
        }
        let length = b - a
        func shift(_ t: Double) -> Double { t <= a ? t : t >= b ? t - length : a }
        var next = edit
        next.clips = kept.filter { $0.duration > 0.01 }
        next.zooms = zooms.compactMap { z in
            var z = z
            z.start = shift(z.start)
            z.end = shift(z.end)
            return z.end - z.start >= 0.3 ? z : nil
        }
        edit = next
    }

    func deleteClip(_ id: UUID) {
        guard clips.count > 1, let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips.remove(at: i)
        clampZooms()
    }

    /// Removes a cut marker: puts the removed stretch back, or joins the two clips of a split.
    func restoreCut(at t: Double) {
        let starts = clipStarts
        if t < 0.01, var first = clips.first { first.start = 0; clips[0] = first }
        else if abs(t - duration) < 0.01, var last = clips.last { last.end = sourceDuration; clips[clips.count - 1] = last }
        else if let i = starts.firstIndex(where: { abs($0 - t) < 0.01 }), i > 0 {
            let merged = VideoClip(start: clips[i - 1].start, end: clips[i].end)
            clips.replaceSubrange((i - 1)...i, with: [merged])
        }
        clampZooms()
    }

    /// Keeps zooms inside the (possibly shorter) timeline.
    func clampZooms() {
        let d = duration
        zooms = zooms.compactMap { z in
            var z = z
            z.end = min(z.end, d)
            return z.end - z.start >= 0.3 ? z : nil
        }
    }

    // MARK: Rendering

    /// The output frame size: the video, or the background canvas around it.
    var renderSize: CGSize { VideoFrameRenderer.canvas(for: sourceSize, background: background).size }

    /// A snapshot for the frame renderer (the background picture is drawn here, on the main thread).
    /// `includeBackground: false` is the editor preview: just the video with its zooms (the editor draws the
    /// background, padding, corners and shadow around it as layers, so those settings change instantly).
    func renderSettings(outputScale: CGFloat = 1, includeBackground: Bool = true) -> VideoRenderSettings {
        let background = includeBackground ? self.background : VideoBackground()
        let canvas = VideoFrameRenderer.canvas(for: sourceSize, background: background)
        var backdrop: CGImage?
        if background.isVisible { backdrop = Self.drawBackdrop(background.fill, size: canvas.size) }
        return VideoRenderSettings(sourceSize: sourceSize, canvasSize: canvas.size, card: canvas.card, backdrop: backdrop,
                                   shadow: background.isVisible ? background.shadow : 0,
                                   cornerRadius: background.corners * VideoBackground.maxCornerFraction * min(canvas.card.width, canvas.card.height),
                                   zooms: zooms, animation: zoomAnimation, motionBlur: Double(motionBlur) / 3, outputScale: outputScale)
    }

    /// The backdrop for the editor preview (cached per fill; shown aspect-filled behind the video).
    func previewBackdrop() -> CGImage? {
        if let cached = backdropCache, cached.fill == background.fill { return cached.image }
        let aspect = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 16 / 9
        let image = Self.drawBackdrop(background.fill, size: CGSize(width: 1200, height: (1200 / aspect).rounded()))
        backdropCache = (background.fill, image)
        return image
    }
    private var backdropCache: (fill: BackgroundStyle.Fill, image: CGImage?)?

    static func drawBackdrop(_ fill: BackgroundStyle.Fill, size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        // Gradients are designed y-down.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        switch fill {
        case .gradient(let index): BackgroundPalette.drawGradient(index, in: rect, ctx: ctx)
        case .color(let hex): ctx.setFillColor(BackgroundPalette.nsColor(hex).cgColor); ctx.fill(rect)
        case .transparent: ctx.clear(rect)
        default:
            if let image = BackgroundImages.shared.image(for: fill) {
                // Aspect fill (the context is flipped, so draw the image flipped back).
                let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
                let iw = CGFloat(image.width) * scale, ih = CGFloat(image.height) * scale
                ctx.saveGState()
                ctx.translateBy(x: 0, y: rect.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(x: (rect.width - iw) / 2, y: (rect.height - ih) / 2, width: iw, height: ih))
                ctx.restoreGState()
            } else {
                ctx.setFillColor(NSColor.darkGray.cgColor)
                ctx.fill(rect)
            }
        }
        return ctx.makeImage()
    }

    /// The edit as a composition (clips back to back) plus the volume.
    func makeComposition() async throws -> (AVMutableComposition, AVMutableAudioMix?) {
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let source = videoTracks.first,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        video.preferredTransform = try await source.load(.preferredTransform)
        let audio = audioTracks.compactMap { _ in composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        var at = CMTime.zero
        for clip in clips {
            let range = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                    end: CMTime(seconds: clip.end, preferredTimescale: 600))
            try video.insertTimeRange(range, of: source, at: at)
            for (track, sourceAudio) in zip(audio, audioTracks) { try? track.insertTimeRange(range, of: sourceAudio, at: at) }
            at = at + range.duration
        }
        return (composition, audio.isEmpty ? nil : audioMix(for: audio))
    }

    /// The volume as an audio mix (Include audio off = silent).
    func audioMix(for tracks: [AVAssetTrack]) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(includeAudio ? Float(volume) : 0, at: .zero)
            return params
        }
        return mix
    }
}

/// Everything the frame renderer needs, readable from AVFoundation's rendering threads.
struct VideoRenderSettings: @unchecked Sendable {
    var sourceSize: CGSize
    var canvasSize: CGSize
    /// Where the video sits on the canvas (y-up, like Core Image).
    var card: CGRect
    var backdrop: CGImage?
    var shadow: Double
    var cornerRadius: CGFloat
    var zooms: [VideoZoom]
    var animation: ZoomAnimation
    /// 0…1.
    var motionBlur: Double
    /// Export at a lower resolution than the canvas.
    var outputScale: CGFloat
}

/// Draws one output frame: zoom into the video, then place it on the background (corners, shadow).
nonisolated final class VideoFrameRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: VideoRenderSettings
    /// The static layers, made once per settings: backdrop + shadow, and the corner mask.
    private var base: CIImage?
    private var mask: CIImage?

    init(_ settings: VideoRenderSettings) { self.settings = settings }

    func update(_ settings: VideoRenderSettings) {
        lock.lock()
        self.settings = settings
        base = nil
        mask = nil
        lock.unlock()
    }

    /// The canvas around a video: padding on every side, widened to a fixed ratio if one is picked.
    static func canvas(for video: CGSize, background: VideoBackground) -> (size: CGSize, card: CGRect) {
        guard background.isVisible, video.width > 0 else { return (video, CGRect(origin: .zero, size: video)) }
        // The output keeps the video's own pixel size (Auto) or that size widened to the ratio; padding never changes
        // it: the video shrinks inside the canvas instead.
        var size = video
        if let r = background.ratio.value {
            if size.width / size.height < r { size.width = size.height * r } else { size.height = size.width / r }
        }
        // Even pixel sizes keep H.264 happy.
        size = CGSize(width: (size.width / 2).rounded() * 2, height: (size.height / 2).rounded() * 2)
        let pad = background.padding * 0.25 * min(size.width, size.height)
        let inner = CGSize(width: max(size.width - pad * 2, 2), height: max(size.height - pad * 2, 2))
        let s = min(inner.width / video.width, inner.height / video.height, 1)
        let w = video.width * s, h = video.height * s
        let card = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
        return (size, card)
    }

    /// Smooth: nearly straight, with short eased ends (constant speed in the middle, max slope 1.33).
    static func softLinear(_ p: Double) -> Double {
        let a = 0.25
        if p < a { return p * p / (2 * a * (1 - a)) }
        if p > 1 - a { return 1 - (1 - p) * (1 - p) / (2 * a * (1 - a)) }
        return (p - a / 2) / (1 - a)
    }

    /// What a zoom shows (unit rect, top-left origin): a rectangle 1/scale in size centered on the
    /// focus point, pushed back inside the frame per axis when the point is near an edge (x and y independently).
    static func zoomTarget(_ z: VideoZoom) -> CGRect {
        let size = 1 / max(z.scale, 1)
        return CGRect(x: min(max(z.center.x - size / 2, 0), 1 - size), y: min(max(z.center.y - size / 2, 0), 1 - size),
                      width: size, height: size)
    }

    /// Between two views: the size changes geometrically (an even zoom speed) and the position follows the size
    /// change, so the rectangle heads straight for its target without sliding; same-size moves just pan.
    static func blend(_ a: CGRect, _ b: CGRect, _ p: Double) -> CGRect {
        let size = a.width * pow(b.width / a.width, CGFloat(p))
        let q = abs(a.width - b.width) > 0.0001 ? (a.width - size) / (a.width - b.width) : CGFloat(p)
        return CGRect(x: a.minX + (b.minX - a.minX) * q, y: a.minY + (b.minY - a.minY) * q, width: size, height: size)
    }

    /// The visible part of the video at `t` (unit rect, top-left origin) and how fast it's changing.
    /// ~0.55 s ramps at the start and end of a zoom block (Smooth: nearly linear; Dynamic: a
    /// quicker steep ease-in-out). Zooms that touch (e.g. after "Split") glide from one view to the next instead of
    /// zooming out and back in.
    static func zoomRect(at t: Double, zooms: [VideoZoom], animation: ZoomAnimation) -> (rect: CGRect, velocity: Double) {
        let sorted = zooms.sorted { $0.start < $1.start }
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        func ease(_ p: Double) -> Double {
            let p = min(max(p, 0), 1)
            // Smooth: a gentle ease-in-out; Dynamic: steeper.
            return animation == .smooth ? (1 - cos(.pi * p)) / 2 : (p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2)
        }
        func rect(_ t: Double) -> CGRect {
            guard let i = sorted.firstIndex(where: { t >= $0.start && t < $0.end }) else { return full }
            let z = sorted[i]
            let ramp = min(animation == .smooth ? 0.55 : 0.32, (z.end - z.start) / 2)
            let touchesPrevious = i > 0 && abs(sorted[i - 1].end - z.start) < 0.05
            let next = i + 1 < sorted.count && abs(sorted[i + 1].start - z.end) < 0.05 ? sorted[i + 1] : nil
            let target = zoomTarget(z)
            if let next, t > z.end - ramp { return blend(target, zoomTarget(next), ease((t - (z.end - ramp)) / ramp)) }
            if !touchesPrevious, t < z.start + ramp { return blend(full, target, ease((t - z.start) / ramp)) }
            if next == nil, t > z.end - ramp { return blend(full, target, ease((z.end - t) / ramp)) }
            return target
        }
        let now = rect(t), next = rect(t + 1.0 / 60)
        return (now, Double(abs(next.width - now.width) + abs(next.minX - now.minX) + abs(next.minY - now.minY)) * 60)
    }

    func render(_ source: CIImage, time: Double) -> CIImage {
        lock.lock()
        let s = settings
        if base == nil { makeLayers(s) }
        let base = self.base, mask = self.mask
        lock.unlock()

        // Zoom: crop around the center and scale back up to the video's size.
        var video = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let w = s.sourceSize.width, h = s.sourceSize.height
        let zoom = Self.zoomRect(at: time, zooms: s.zooms, animation: s.animation)
        func zoomed(_ rect: CGRect) -> CIImage {
            guard rect.width < 0.999 else { return video }
            let scale = 1 / rect.width
            // Core Image is y-up: flip the top-left based rectangle.
            let crop = CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h)
            return video.clampedToExtent().cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        if s.motionBlur > 0, zoom.velocity > 0.01 {
            // A camera-style motion blur, very subtle: the frame is the average of the zoom at several
            // moments within the shutter (Low/Medium/High = ⅓, ⅔, a full 1/120 s), i.e. frame interpolation.
            let shutter = s.motionBlur / 120
            let samples = 3
            // A running average: the k-th sample is mixed in with weight 1/(k+1) (a plain cross-dissolve), so the
            // brightness stays exactly the same.
            var average: CIImage?
            for k in 0..<samples {
                let dt = (Double(k) / Double(samples - 1) - 0.5) * shutter
                let layer = zoomed(Self.zoomRect(at: time + dt, zooms: s.zooms, animation: s.animation).rect)
                average = average.map {
                    $0.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: layer, kCIInputTimeKey: 1.0 / Double(k + 1)])
                } ?? layer
            }
            video = (average ?? zoomed(zoom.rect)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            video = zoomed(zoom.rect)
        }

        var output = video
        if let base, let mask {
            let k = s.card.width / max(s.sourceSize.width, 1)
            let placed = video.transformed(by: CGAffineTransform(scaleX: k, y: k).concatenating(CGAffineTransform(translationX: s.card.minX, y: s.card.minY)))
            output = placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
        }
        if s.outputScale < 0.999 { output = output.transformed(by: CGAffineTransform(scaleX: s.outputScale, y: s.outputScale)) }
        let size = CGSize(width: (s.canvasSize.width * s.outputScale / 2).rounded() * 2, height: (s.canvasSize.height * s.outputScale / 2).rounded() * 2)
        return output.cropped(to: CGRect(origin: .zero, size: size))
    }

    private func makeLayers(_ s: VideoRenderSettings) {
        guard let backdrop = s.backdrop else { base = nil; mask = nil; return }
        let canvas = CGRect(origin: .zero, size: s.canvasSize)
        var layer = CIImage(cgImage: backdrop).cropped(to: canvas)
        let shape = CGPath(roundedRect: s.card, cornerWidth: s.cornerRadius, cornerHeight: s.cornerRadius, transform: nil)
        // The screenshot Background tool's shadow, scaled to the video's card.
        let k = min(s.card.width, s.card.height) / BackgroundShadow.measuredShortSide
        for l in BackgroundShadow.layers(s.shadow) {
            if let shadow = Self.shape(shape, size: s.canvasSize, color: CGColor(gray: 0, alpha: l.opacity)) {
                let soft = shadow.clampedToExtent().applyingGaussianBlur(sigma: l.sigma * k)
                    .transformed(by: CGAffineTransform(translationX: 0, y: -l.offset * k)).cropped(to: canvas)
                layer = soft.composited(over: layer)
            }
        }
        base = layer
        mask = Self.shape(shape, size: s.canvasSize, color: CGColor(gray: 1, alpha: 1))
    }

    private static func shape(_ path: CGPath, size: CGSize, color: CGColor) -> CIImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// The preview/export composition: every frame goes through `render`.
    static func videoComposition(for asset: AVAsset, renderer: VideoFrameRenderer, renderSize: CGSize, frameRate: Double) async throws -> AVMutableVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
            let image = renderer.render(request.sourceImage, time: request.compositionTime.seconds)
            request.finish(with: image, context: nil)
        }
        composition.renderSize = renderSize
        // At most 60 fps: variable-rate screen recordings report up to 120.
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(min(max(frameRate, 1), 60).rounded()))
        return composition
    }
}
