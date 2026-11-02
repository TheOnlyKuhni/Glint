import AppKit
import AVFoundation

/// What a Studio Mode recording keeps next to its video (which has no cursor): the pointer's path and clicks, the
/// cursor shapes, the keys pressed and a separate camera movie. The video editor draws them afterwards, so the cursor,
/// click effects, keystrokes and camera can all be changed after recording.
///
/// On disk: `<capture folder>/Studio/studio.json`, `cursor-<n>.png` and `camera.mov`.
struct StudioRecording: Codable {
    /// One pointer event. `t` is video time (s); `x`/`y` are relative to the recorded area (0…1, top-left origin,
    /// outside the area < 0 or > 1); `c` indexes `cursors`.
    struct Mouse: Codable {
        var t: Double
        var x: Double
        var y: Double
        var k: Kind
        var c: Int
    }

    enum Kind: Int, Codable { case move, down, up, rightDown, rightUp, scroll }

    /// One key press (video time, key code, the key's character without modifiers, the modifier flags).
    struct Key: Codable {
        var t: Double
        var code: Int
        var chars: String
        var flags: UInt
    }

    enum CursorType: String, Codable { case arrow, pointingHand, iBeam, crosshair, openHand, closedHand, other }

    /// A cursor shape seen while recording: its picture, hot spot and size in points.
    struct Cursor: Codable {
        var file: String
        var hotX: Double
        var hotY: Double
        var width: Double
        var height: Double
        var type: CursorType
    }

    var version = 1
    /// The recorded area in points.
    var areaWidth: Double
    var areaHeight: Double
    var mouse: [Mouse] = []
    var keys: [Key] = []
    var cursors: [Cursor] = []
    /// Keystrokes could be recorded (Input Monitoring was allowed).
    var keysRecorded = false
    /// The camera movie's file name, and when its first frame happens on the video's timeline.
    var camera: String?
    var cameraOffset: Double = 0
    /// The recorder panel's settings at the start: the editor starts from them.
    var highlightedClicks = false
    var showedKeystrokes = false
    var cameraShape = 0
    var cameraSize = 1
    var cameraFlipped = true

    static func folder(for video: URL) -> URL { video.deletingLastPathComponent().appendingPathComponent("Studio") }

    static func load(for video: URL) -> StudioRecording? {
        let file = folder(for: video).appendingPathComponent("studio.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let data = try? Data(contentsOf: file) else { glintLog("studio: can't open \(file.path)"); return nil }
        do { return try JSONDecoder().decode(StudioRecording.self, from: data) } catch {
            glintLog("studio: can't read \(file.path): \(error)")
            return nil
        }
    }

    func write(to folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent("studio.json"))
    }
}

/// Maps host time (seconds, the clock of events and capture buffers) to the recording's video time, leaving out the
/// paused stretches exactly like the screen recorder does. Thread-safe: the camera queue asks too.
nonisolated final class RecordingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    private var gaps: [(start: Double, end: Double)] = []
    private var openGap: Double?

    /// Restart: the recording begins again.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        first = nil
        gaps = []
        openGap = nil
    }

    /// The first video frame was written at `host`.
    func started(at host: Double) {
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = host }
    }

    /// Pausing at the last written frame `host` (later frames are dropped until `resumed`).
    func paused(at host: Double) {
        lock.lock(); defer { lock.unlock() }
        if openGap == nil { openGap = host }
    }

    /// The first frame after a pause.
    func resumed(at host: Double) {
        lock.lock(); defer { lock.unlock() }
        if let start = openGap { gaps.append((start, host)) }
        openGap = nil
    }

    /// Video time for a host time, or nil before the first frame and while paused.
    func videoTime(_ host: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let first, host >= first else { return nil }
        if let openGap, host >= openGap { return nil }
        var t = host - first
        for gap in gaps {
            if host >= gap.end { t -= gap.end - gap.start } else if host >= gap.start { return nil }
        }
        return t
    }
}

/// Records the pointer, the cursor shapes and the keys while a Studio Mode recording runs.
final class StudioTracker {
    private let area: CGRect
    private let folder: URL
    private let clock: RecordingClock
    private var data: StudioRecording
    private var monitors: [Any] = []
    private var cursorTimer: Timer?
    private var cursorIndex = 0
    private var fingerprints: [[UInt8]] = []
    private static let knownTypes: [(StudioRecording.CursorType, NSCursor)] = [
        (.arrow, .arrow), (.pointingHand, .pointingHand), (.iBeam, .iBeam), (.crosshair, .crosshair),
        (.openHand, .openHand), (.closedHand, .closedHand),
    ]
    private lazy var knownFingerprints = Self.knownTypes.map { ($0.0, Self.fingerprint($0.1)) }

    /// `area`: the recorded area in global CG points.
    init(area: CGRect, folder: URL, clock: RecordingClock) {
        self.area = area
        self.folder = folder
        self.clock = clock
        data = StudioRecording(areaWidth: area.width, areaHeight: area.height)
        data.highlightedClicks = Defaults[Prefs.recHighlightClicks]
        data.showedKeystrokes = Defaults[Prefs.recShowKeystrokes]
        data.cameraShape = Defaults[Prefs.recCameraShape]
        data.cameraSize = Defaults[Prefs.recCameraSize]
        data.cameraFlipped = Defaults[Prefs.recCameraFlip]
        data.keysRecorded = KeystrokePermission.isGranted
    }

    func start() {
        // The arrow is always cursor 0, so there's a shape even before the first sample.
        _ = index(of: .arrow)
        sampleCursor()
        let mouse: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { [weak self] in self?.mouse($0) }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mouse, handler: { [weak self] in self?.mouse($0); return $0 }) { monitors.append(m) }
        if data.keysRecorded {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.key($0) }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] in self?.key($0); return $0 }) { monitors.append(m) }
        }
        // Cursor shapes change without mouse events (hovering a link while scrolling, an app taking over).
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.sampleCursor() }
    }

    /// Restart: everything so far is dropped (the cursor pictures stay).
    func reset() {
        data.mouse = []
        data.keys = []
    }

    /// Stops tracking and returns what was recorded (the camera fields are filled in by the session).
    func finish() -> StudioRecording {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        cursorTimer?.invalidate()
        return data
    }

    // MARK: Events

    private func position() -> (Double, Double) {
        let p = Geometry.cgPoint(fromAppKit: NSEvent.mouseLocation)
        return (Double((p.x - area.minX) / max(area.width, 1)), Double((p.y - area.minY) / max(area.height, 1)))
    }

    private func append(_ kind: StudioRecording.Kind, host: Double) {
        guard let t = clock.videoTime(host) else { return }
        let (x, y) = position()
        // Plain moves closer than 1/240 s apart add nothing (trackpads report several per frame).
        if kind == .move, let last = data.mouse.last, last.k == .move, t - last.t < 1.0 / 240, last.c == cursorIndex { return }
        data.mouse.append(.init(t: t, x: x, y: y, k: kind, c: cursorIndex))
    }

    private func mouse(_ event: NSEvent) {
        let kind: StudioRecording.Kind = switch event.type {
        case .leftMouseDown: .down
        case .leftMouseUp: .up
        case .rightMouseDown: .rightDown
        case .rightMouseUp: .rightUp
        case .scrollWheel: .scroll
        default: .move
        }
        append(kind, host: event.timestamp)
    }

    private func key(_ event: NSEvent) {
        guard !event.isARepeat || event.modifierFlags.contains(.command), let t = clock.videoTime(event.timestamp) else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        data.keys.append(.init(t: t, code: Int(event.keyCode), chars: event.charactersIgnoringModifiers ?? "", flags: UInt(flags)))
    }

    // MARK: Cursor shapes

    private func sampleCursor() {
        guard let cursor = NSCursor.currentSystem else { return }
        let i = index(of: cursor)
        // Also the first sample once the video runs: a pointer that never moves still has a place.
        guard i != cursorIndex || data.mouse.isEmpty else { return }
        cursorIndex = i
        append(.move, host: ProcessInfo.processInfo.systemUptime)
    }

    /// The cursor's index in the recording, saving its picture the first time it's seen.
    private func index(of cursor: NSCursor) -> Int {
        let print = Self.fingerprint(cursor)
        if let i = fingerprints.firstIndex(where: { Self.matches($0, print) }) { return i }
        let i = fingerprints.count
        fingerprints.append(print)
        let type = knownFingerprints.first { Self.matches($0.1, print) }?.0 ?? .other
        let size = cursor.image.size
        let file = "cursor-\(i).png"
        if let png = Self.png(cursor.image) { try? png.write(to: folder.appendingPathComponent(file)) }
        data.cursors.append(.init(file: file, hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y, width: size.width, height: size.height, type: type))
        return i
    }

    /// A 16×16 gray + alpha thumbnail plus the size and hot spot: enough to tell cursor shapes apart cheaply.
    private static func fingerprint(_ cursor: NSCursor) -> [UInt8] {
        let n = 16
        var pixels = [UInt8](repeating: 0, count: n * n * 2)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 2,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let image = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        let s = cursor.image.size, h = cursor.hotSpot
        return pixels + [UInt8(min(s.width, 255)), UInt8(min(s.height, 255)), UInt8(min(max(h.x, 0), 255)), UInt8(min(max(h.y, 0), 255))]
    }

    private static func matches(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, a.suffix(4) == b.suffix(4) else { return false }
        var diff = 0
        for i in 0..<(a.count - 4) { diff += abs(Int(a[i]) - Int(b[i])) }
        return diff / (a.count - 4) < 8
    }

    /// The cursor picture at 2× (its sharpest).
    private static func png(_ image: NSImage) -> Data? {
        let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
        guard w > 0, h > 0, let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Writes the camera to its own movie while a Studio Mode recording runs (frames as the camera delivers them,
/// timed on the video's timeline by the recording clock, unmirrored).
nonisolated final class CameraFileRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let url: URL
    let output = AVCaptureVideoDataOutput()
    private let clock: RecordingClock
    private let queue = DispatchQueue(label: "com.philippk.glint.camera-file")
    // Guarded by `queue`.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstTime: Double?
    private var stopped = false

    init(url: URL, clock: RecordingClock) {
        self.url = url
        self.clock = clock
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, let image = CMSampleBufferGetImageBuffer(buffer),
              let t = clock.videoTime(buffer.presentationTimeStamp.seconds) else { return }
        if writer == nil {
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { stopped = true; return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: w * h * 4],
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            guard writer.startWriting() else { glintLog("camera file: \(String(describing: writer.error))"); stopped = true; return }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            firstTime = t
        }
        guard let input, input.isReadyForMoreMediaData, let firstTime else { return }
        // Retimed onto the video's clock (paused stretches are already left out), starting at zero.
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: t - firstTime, preferredTimescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                              sampleBufferOut: &retimed)
        if let retimed { input.append(retimed) }
    }

    /// Restart: the movie so far is thrown away and a new one starts with the next frame.
    func reset() {
        queue.async { [self] in
            writer?.cancelWriting()
            writer = nil
            input = nil
            firstTime = nil
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Finishes the movie; returns when its first frame happens on the video's timeline (nil: nothing recorded).
    func finish() async -> Double? {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                stopped = true
                guard let writer, let input, let firstTime else { cont.resume(returning: nil); return }
                input.markAsFinished()
                writer.finishWriting { cont.resume(returning: writer.status == .completed ? firstTime : nil) }
            }
        }
    }
}
