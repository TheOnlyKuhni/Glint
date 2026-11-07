import AVFoundation
import CoreImage
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Records a screen area to an H.264 movie with ScreenCaptureKit and AVAssetWriter.
/// Pausing drops frames and shifts later timestamps back, so the movie has no gap.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Options {
        /// Global CG coordinates, points.
        var rect: CGRect
        var screen: NSScreen
        var frameRate: Int
        var showsCursor: Bool
        var systemAudio: Bool
        /// Microphone device unique ID; empty = no microphone.
        var microphone: String
        /// GIFs are recorded silently, then converted.
        var isGIF: Bool
        /// Studio Mode: nothing of Glint is recorded (the camera goes into its own movie).
        var isStudio = false
    }

    let options: Options
    let outputURL: URL
    /// Video time for event timestamps (Studio Mode lines the pointer, keys and camera up with it).
    let clock: RecordingClock
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "glint.recorder")
    // Guarded by `queue`.
    private var started = false
    private var paused = false
    private var pausedTotal = CMTime.zero
    private var pauseBegan: CMTime?
    private var lastVideoTime = CMTime.zero
    /// The newest frame: frames only come when the screen changes, so it's repeated at the end.
    private var lastVideoFrame: CMSampleBuffer?
    /// Frames are placed on an exact grid of the chosen frame rate (time of the first frame + n / rate), at most one
    /// per step. The display delivers frames on its own refresh (60 Hz: 24 fps came out as ~21 fps, and 30 fps had
    /// some 1/60 s steps that made the video editor treat it as 60 fps).
    private var gridStart: CMTime?
    private var lastSlot = -1
    private var fps: Int32 { Int32(max(options.frameRate, 1)) }
    private var frameDuration: CMTime { CMTime(value: 1, timescale: fps) }

    init(options: Options, clock: RecordingClock = RecordingClock()) {
        self.options = options
        self.clock = clock
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GlintRecording-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outputURL = dir.appendingPathComponent("recording.mp4")
    }

    /// Pixel size of the movie: the area at the display's scale (or 1x), capped by "Max resolution"; always even.
    var pixelSize: CGSize {
        let scale = Defaults[Prefs.recScaleTo1x] || options.isGIF ? 1 : options.screen.backingScaleFactor
        var size = CGSize(width: options.rect.width * scale, height: options.rect.height * scale)
        let cap: CGFloat? = switch Defaults[Prefs.recMaxResolution] {
        case .original: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        }
        if let cap, min(size.width, size.height) > cap {
            let f = cap / min(size.width, size.height)
            size = CGSize(width: size.width * f, height: size.height * f)
        }
        return CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }

    func start() async throws {
        let content = try await ScreenCapturer.content()
        guard let display = content.displays.first(where: { $0.displayID == options.screen.displayID }) else { throw CaptureError.noDisplay }
        let filter = contentFilter(display: display, content: content)
        let size = pixelSize
        let config = SCStreamConfiguration()
        config.sourceRect = options.rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(size.width)
        config.height = Int(size.height)
        // Twice the frame rate, so every step of the grid gets a frame close to its time.
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps * 2)
        config.showsCursor = options.showsCursor
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        if !options.isGIF {
            config.capturesAudio = options.systemAudio
            config.excludesCurrentProcessAudio = true
            config.channelCount = Defaults[Prefs.recMono] ? 1 : 2
            if #available(macOS 15.0, *), !options.microphone.isEmpty {
                config.captureMicrophone = true
                config.microphoneCaptureDeviceID = options.microphone
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 6),
                AVVideoExpectedSourceFrameRateKey: options.frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: Defaults[Prefs.recMono] ? 1 : 2, AVEncoderBitRateKey: 160_000,
        ]
        if config.capturesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }
        if !options.isGIF, !options.microphone.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micInput = input
        }
        self.writer = writer
        videoInput = video

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if config.capturesAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if #available(macOS 15.0, *), micInput != nil { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        self.stream = stream
        try await stream.startCapture()
    }

    private func contentFilter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        // Glint's controls stay out of the movie; click highlights and keystrokes are meant to be recorded.
        let pid = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.owningApplication?.processID == pid && $0.title != RecordingOverlayTitle.recorded }
        // Studio Mode records none of Glint: the whole app is left out, so a window that appears or is replaced
        // later (the camera bubble) can't slip in the way one missing from this snapshot of the windows would.
        if options.isStudio, let glint = content.applications.first(where: { $0.processID == pid }) {
            return SCContentFilter(display: display, excludingApplications: [glint], exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: excluded)
    }

    /// Leaves out windows opened since the recording started (the filter lists them one by one): the control bar.
    /// All windows, as the on-screen list doesn't have one that was just opened.
    func updateExcludedWindows() async {
        guard let stream, let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let display = content.displays.first(where: { $0.displayID == options.screen.displayID }) else { return }
        try? await stream.updateContentFilter(contentFilter(display: display, content: content))
    }

    func setPaused(_ value: Bool) {
        queue.async { [self] in
            guard paused != value else { return }
            paused = value
            if value {
                pauseBegan = lastVideoTime
                clock.paused(at: lastVideoTime.seconds)
            }
        }
    }

    /// Finishes the movie. Returns nil if nothing was recorded.
    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { cont in
            queue.async { [self] in
                guard let writer, started else { cont.resume(returning: nil); return }
                appendFinalFrame()
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                micInput?.markAsFinished()
                writer.finishWriting { [outputURL] in cont.resume(returning: writer.status == .completed ? outputURL : nil) }
            }
        }
    }

    /// Holds the picture until Stop: a screen that stopped changing delivers no frames, and the video would end early
    /// (long before the sound). The stream's timestamps run on the host clock.
    private func appendFinalFrame() {
        guard !paused, let frame = lastVideoFrame else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        lastVideoFrame = nil
        guard now > lastVideoTime else { return }
        appendFrame(frame, at: now)
    }

    /// Writes a frame at its step on the frame-rate grid; a second frame for the same step is dropped.
    private func appendFrame(_ buffer: CMSampleBuffer, at time: CMTime) {
        let shifted = time - pausedTotal
        let start = gridStart ?? shifted
        gridStart = start
        let slot = Int(((shifted - start).seconds * Double(fps)).rounded())
        guard slot > lastSlot, let input = videoInput, input.isReadyForMoreMediaData else { return }
        lastSlot = slot
        let pts = start + CMTime(value: CMTimeValue(slot), timescale: fps)
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy)
        if let copy { input.append(copy) }
    }

    func discard() {
        Task {
            try? await stream?.stopCapture()
            queue.async { [self] in
                writer?.cancelWriting()
                try? FileManager.default.removeItem(at: outputURL.deletingLastPathComponent())
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid, let writer else { return }
        let time = buffer.presentationTimeStamp
        if type == .screen {
            // Only complete frames carry new pixels.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                guard writer.startWriting() else { glintLog("recorder: \(String(describing: writer.error))"); return }
                writer.startSession(atSourceTime: time)
                started = true
                clock.started(at: time.seconds)
            }
            if paused { return }
            if let began = pauseBegan {
                // The first frame after the pause comes one step after the last one before it.
                let gap = CMTimeMaximum(time - began - frameDuration, .zero)
                pausedTotal = pausedTotal + gap
                pauseBegan = nil
                clock.resumed(at: (began + gap).seconds)
            }
            lastVideoTime = time
            lastVideoFrame = buffer
            appendFrame(buffer, at: time)
        } else {
            guard started, !paused else { return }
            append(buffer, to: type == .audio ? audioInput : micInput)
        }
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, input.isReadyForMoreMediaData else { return }
        if pausedTotal == .zero { input.append(buffer); return }
        var timing = CMSampleTimingInfo(duration: buffer.duration, presentationTimeStamp: buffer.presentationTimeStamp - pausedTotal,
                                        decodeTimeStamp: .invalid)
        var shifted: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &shifted)
        if let shifted { input.append(shifted) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        glintLog("recorder stopped: \(error.localizedDescription)")
    }
}

/// Window titles: Glint windows with this title are recorded (click highlights, keystrokes, webcam).
enum RecordingOverlayTitle {
    static let recorded = "GlintRecorded"
}

/// Converts a recorded movie to a GIF with the GIF settings (frame rate, width, quality).
/// "Optimize GIFs" merges repeated frames into one longer frame. ImageIO already stores only the changed part of each
/// frame; making unchanged pixels transparent on top of that made GIFs 1.6–2.7× bigger (measured), so Glint doesn't.
/// "Quality" below High reduces the colors (posterize) for smaller files.
enum GIFEncoder {
    /// `width`: the GIF's width (default: the GIF Resolution setting), never wider than the movie.
    static func encode(movie: URL, to output: URL, range: CMTimeRange? = nil, width maxWidth: Int? = nil) async -> Bool {
        let asset = AVURLAsset(url: movie)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize) else { return false }
        let fps = Double(max(Defaults[Prefs.gifFrameRate], 1))
        let width = min(CGFloat(maxWidth ?? Defaults[Prefs.gifResolution]), natural.width)
        let size = CGSize(width: width.rounded(), height: (natural.height * width / natural.width).rounded())
        let optimize = Defaults[Prefs.gifOptimize]
        let quality = Defaults[Prefs.gifQuality]
        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = size
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let start = range?.start.seconds ?? 0
        let length = range?.duration.seconds ?? duration.seconds
        let count = max(1, Int(length * fps))
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else { return false }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let times = (0..<count).map { CMTime(seconds: start + Double($0) / fps, preferredTimescale: 600) }
        let frameTime = 1 / fps
        let writer = GIFFrameWriter(destination: dest, size: size, optimize: optimize,
                                    posterizeLevels: quality >= 0.75 ? nil : Int(6 + quality * 24))
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            writer.add(image, duration: frameTime)
        }
        writer.flush()
        return CGImageDestinationFinalize(dest)
    }
}

/// Buffers one frame so repeats can extend its delay (when optimizing).
nonisolated private final class GIFFrameWriter {
    private let destination: CGImageDestination
    private let size: CGSize
    private let optimize: Bool
    private let posterizeLevels: Int?
    private let ciContext = CIContext()
    private var pending: (pixels: [UInt32], delay: Double)?
    /// The frames' exact length so far and what their rounded delays add up to, in hundredths of a second.
    private var exactTime = 0.0
    private var writtenTime = 0.0

    init(destination: CGImageDestination, size: CGSize, optimize: Bool, posterizeLevels: Int?) {
        self.destination = destination
        self.size = size
        self.optimize = optimize
        self.posterizeLevels = posterizeLevels
    }

    func add(_ image: CGImage, duration: Double) {
        guard let pixels = pixels(of: prepared(image)) else { return }
        if let p = pending, optimize, p.pixels == pixels {
            pending?.delay += duration
            return
        }
        flush()
        pending = (pixels, duration)
    }

    func flush() {
        guard let p = pending else { return }
        pending = nil
        guard let image = makeImage(p.pixels) else { return }
        // GIF delays are whole hundredths of a second. The rounding error carries over to the next frame, or a 30 fps
        // GIF (3 instead of 3.33) would run 10% fast. Under 2, players slow a frame down instead.
        exactTime += p.delay * 100
        let hundredths = max((exactTime - writtenTime).rounded(), 2)
        writtenTime += hundredths
        let delay = hundredths / 100
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        CGImageDestinationAddImage(destination, image, props)
    }

    private func prepared(_ image: CGImage) -> CGImage {
        guard let levels = posterizeLevels else { return image }
        let ci = CIImage(cgImage: image).applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
        return ciContext.createCGImage(ci, from: ci.extent) ?? image
    }

    private var w: Int { Int(size.width) }
    private var h: Int { Int(size.height) }

    /// Opaque RGBA pixels (alpha forced to 255) at the GIF size.
    private func pixels(of image: CGImage) -> [UInt32]? {
        var buffer = [UInt32](repeating: 0, count: w * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buffer : nil
    }

    private func makeImage(_ pixels: [UInt32]) -> CGImage? {
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
