import AppKit
import AVFoundation
import SwiftUI

/// What the export sheet can make.
enum VideoExportFormat: CaseIterable {
    case mp4, mov, gif
    var title: String {
        switch self {
        case .mp4: "MP4"
        case .mov: "MOV"
        case .gif: "GIF"
        }
    }
    var fileExtension: String { title.lowercased() }
    var help: String {
        switch self {
        case .mp4: "H.264 video that plays nearly everywhere"
        case .mov: "The same video in Apple's QuickTime container"
        case .gif: "An animated picture without sound"
        }
    }
}

/// Renders the edit to an H.264 movie: composed frames through the frame renderer at the chosen size and bitrate,
/// audio (with the volume) as AAC.
enum VideoExporter {
    static let qualityNames = ["Low", "Medium", "High", "Best"]
    /// Bits per pixel per frame for each quality.
    private static let bitsPerPixel: [Double] = [0.04, 0.08, 0.14, 0.24]

    static func bitrate(size: CGSize, frameRate: Double, quality: Int) -> Double {
        Double(size.width * size.height) * min(frameRate, 60) * bitsPerPixel[min(max(quality, 0), 3)]
    }

    static func estimatedBytes(project: VideoProject, scale: CGFloat, quality: Int, includeAudio: Bool) -> Double {
        let size = project.renderSize
        let bits = bitrate(size: CGSize(width: size.width * scale, height: size.height * scale), frameRate: project.frameRate, quality: quality)
            + (includeAudio && project.hasAudio ? 128_000 : 0)
        return bits * project.duration / 8
    }

    /// Writes the export to a temporary file and returns it.
    static func export(project: VideoProject, scale: CGFloat, quality: Int, includeAudio: Bool, fileType: AVFileType = .mp4,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (composition, mix) = try await project.makeComposition()
        let settings = project.renderSettings(outputScale: scale)
        let renderer = VideoFrameRenderer(settings)
        let size = CGSize(width: (settings.canvasSize.width * scale / 2).rounded() * 2, height: (settings.canvasSize.height * scale / 2).rounded() * 2)
        let videoComposition = try await VideoFrameRenderer.videoComposition(for: composition, renderer: renderer, renderSize: size,
                                                                             frameRate: project.frameRate)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glint-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = project.url.deletingPathExtension().lastPathComponent
        let url = folder.appendingPathComponent(name).appendingPathExtension(fileType == .mov ? "mov" : "mp4")
        try await write(composition: composition, videoComposition: videoComposition, audioMix: includeAudio ? mix : nil, size: size, fileType: fileType,
                        bitrate: bitrate(size: size, frameRate: project.frameRate, quality: quality), to: url, progress: progress)
        return url
    }

    private nonisolated static func write(composition: AVComposition, videoComposition: AVVideoComposition, audioMix: AVAudioMix?, size: CGSize, fileType: AVFileType,
                                          bitrate: Double, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let duration = try await composition.load(.duration).seconds
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = audioMix == nil ? [] : try await composition.loadTracks(withMediaType: .audio)

        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks,
                                                           videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOut.videoComposition = videoComposition
        reader.add(videoOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(bitrate), AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioPair: (AVAssetReaderAudioMixOutput, AVAssetWriterInput)?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            out.audioMix = audioMix
            reader.add(out)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioPair = (out, input)
        }

        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let box = UncheckedBox((reader, writer))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(videoOut, into: videoIn, label: "video") { time in progress(min(time / max(duration, 0.01), 1)) }
            }
            if let (out, input) = audioPair {
                group.addTask { await pump(out, into: input, label: "audio") { _ in } }
            }
        }
        let (r, w) = box.value
        if r.status == .failed { w.cancelWriting(); throw r.error ?? CocoaError(.fileReadUnknown) }
        await w.finishWriting()
        if w.status != .completed { throw w.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Copies samples from a reader output to a writer input until the output runs dry.
    private nonisolated static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                                         time: @escaping @Sendable (Double) -> Void) async {
        let box = UncheckedBox((output, input))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let queue = DispatchQueue(label: "com.philippk.glint.export.\(label)")
            let (output, input) = box.value
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, !finished {
                    if let sample = output.copyNextSampleBuffer() {
                        time(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                        if !input.append(sample) { finished = true }
                    } else {
                        finished = true
                    }
                }
                if finished {
                    input.markAsFinished()
                    done.resume()
                }
            }
        }
    }
}

/// Moves AVFoundation objects into the export's tasks (they're used from one queue at a time).
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - The sheet

/// The export sheet: Resolution, Quality (High by default), Audio, Estimated file size, Cancel / Export.
/// Export then asks whether to replace the recording or save a new video.
enum VideoExportSheet {
    /// `completion(url, replace)`: the exported movie (nil = cancelled) and whether it replaces the recording.
    static func present(on window: NSWindow, project: VideoProject, completion: @escaping (URL?, Bool) -> Void) {
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 346, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let model = ExportModel(project: project)
        let host = NSHostingView(rootView: ExportSheetView(model: model))
        host.sizingOptions = [.minSize, .maxSize]  // the sheet follows the content (Video and GIF differ in height)
        sheet.contentView = host
        sheet.setContentSize(host.fittingSize)
        model.close = { [weak window, weak sheet] url, replace in
            if let sheet { window?.endSheet(sheet) }
            completion(url, replace)
        }
        model.sheet = sheet
        window.beginSheet(sheet)
    }
}

private final class ExportModel: ObservableObject {
    let project: VideoProject
    @Published var format: VideoExportFormat
    @Published var resolution = 0
    @Published var quality: Double = 2
    @Published var includeAudio: Bool
    @Published var exporting = false
    /// Also write the captions as a subtitles file (.srt) to the export location.
    @Published var saveSubtitles = UserDefaults.standard.bool(forKey: "captions.exportSRT") {
        didSet { UserDefaults.standard.set(saveSubtitles, forKey: "captions.exportSRT") }
    }
    var hasCaptions: Bool { !project.edit.captions.isEmpty && project.edit.showCaptions }
    @Published var progress: Double = 0
    var close: ((URL?, Bool) -> Void)?
    weak var sheet: NSWindow?

    init(project: VideoProject) {
        self.project = project
        includeAudio = project.hasAudio && project.includeAudio
        format = project.url.pathExtension.lowercased() == "mov" ? .mov : .mp4
    }

    /// Original plus the common heights below it.
    var resolutions: [(title: String, scale: CGFloat)] {
        let size = project.renderSize
        var list: [(String, CGFloat)] = [("Original (\(Int(size.width)) × \(Int(size.height)))", 1)]
        for height in [2160.0, 1440, 1080, 720, 480] where height < size.height - 1 {
            let scale = height / size.height
            list.append(("\(Int(height))p (\(Int((size.width * scale / 2).rounded() * 2)) × \(Int(height)))", scale))
        }
        return list
    }

    var estimate: String {
        let bytes = VideoExporter.estimatedBytes(project: project, scale: resolutions[resolution].scale, quality: Int(quality.rounded()), includeAudio: includeAudio)
        return "~" + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Asks Replace Video / Save as New Video / Cancel, then renders.
    func export() {
        guard let sheet else { return }
        // Another format can't take the recording's place.
        guard format.fileExtension == project.url.pathExtension.lowercased() else { render(replace: false); return }
        let alert = NSAlert()
        alert.messageText = "Do you want to replace the existing video?"
        alert.informativeText = "Replace Video updates this recording (you can still re-edit it). Save as New Video keeps the recording and adds a new one."
        alert.addButton(withTitle: "Replace Video")
        alert.addButton(withTitle: "Save as New Video")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sheet) { response in
            MainActor.assumeIsolated {
                switch response {
                case .alertFirstButtonReturn: self.render(replace: true)
                case .alertSecondButtonReturn: self.render(replace: false)
                default: break
                }
            }
        }
    }

    /// The captions as SubRip, named like the video, in the export location (never over an existing file).
    private func writeSubtitles() {
        let folder = FileSaver.exportDirectory
        let name = project.url.deletingPathExtension().lastPathComponent
        var url = folder.appendingPathComponent(name).appendingPathExtension("srt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension("srt")
            n += 1
        }
        do { try SubtitleFile.srt(project.outputCaptions).write(to: url, atomically: true, encoding: .utf8) } catch {
            glintLog("subtitles: \(error)")
        }
    }

    private func render(replace: Bool) {
        exporting = true
        let scale = resolutions[resolution].scale, format = format
        Task {
            do {
                // A GIF is made from a full-size movie, with the GIF settings.
                let url = try await VideoExporter.export(project: project, scale: format == .gif ? 1 : scale, quality: format == .gif ? 3 : Int(quality.rounded()),
                                                         includeAudio: format != .gif && includeAudio, fileType: format == .mov ? .mov : .mp4) { p in
                    Task { @MainActor in self.progress = p }
                }
                if format != .gif, hasCaptions, saveSubtitles { writeSubtitles() }
                guard format == .gif else { close?(url, replace); return }
                let gif = url.deletingPathExtension().appendingPathExtension("gif")
                guard await GIFEncoder.encode(movie: url, to: gif) else { throw CocoaError(.fileWriteUnknown) }
                close?(gif, false)
            } catch {
                glintLog("video export failed: \(error)")
                NSSound.beep()
                exporting = false
            }
        }
    }
}

private struct ExportSheetView: View {
    @ObservedObject var model: ExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Format").font(.system(size: 13, weight: .semibold))
            ChoiceButtons(titles: VideoExportFormat.allCases.map(\.title), selected: VideoExportFormat.allCases.firstIndex(of: model.format) ?? 0,
                          helps: VideoExportFormat.allCases.map(\.help)) { model.format = VideoExportFormat.allCases[$0] }
                .padding(.top, 8)
            Divider().padding(.vertical, 14)
            if model.format == .gif {
                Text("Uses the frame rate, width and quality from Settings → Screen Recording → GIF.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Resolution").font(.system(size: 13, weight: .semibold))
                Picker("", selection: $model.resolution) {
                    ForEach(model.resolutions.indices, id: \.self) { Text(model.resolutions[$0].title).tag($0) }
                }
                .labelsHidden().padding(.top, 8)
                .help("Pixel size of the exported video")
                Divider().padding(.vertical, 14)
                HStack {
                    Text("Quality").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(VideoExporter.qualityNames[Int(model.quality.rounded())]).font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Slider(value: $model.quality, in: 0...3, step: 1).padding(.top, 8)
                    .help("Higher quality looks sharper and makes a bigger file")
                Divider().padding(.vertical, 14)
                HStack {
                    Text("Audio").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle("", isOn: $model.includeAudio).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .disabled(!model.project.hasAudio)
                        .help("Include the video's sound in the export")
                }
                if !model.project.hasAudio {
                    Text("There is no audio in your video.").font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 6)
                }
                Divider().padding(.vertical, 14)
                HStack {
                    Text("Estimated file size").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.estimate).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if model.hasCaptions, model.format != .gif {
                Divider().padding(.vertical, 14)
                Toggle(isOn: $model.saveSubtitles) {
                    Text("Also save subtitles (.srt)").font(.system(size: 13))
                }
                .help("The captions as a subtitles file, saved to your export location (\(FileManager.default.displayName(atPath: FileSaver.exportDirectory.path)))")
            }
            if model.exporting {
                ProgressView(value: model.progress).padding(.top, 16)
            }
            HStack {
                Button("Cancel") { model.close?(nil, false) }.keyboardShortcut(.cancelAction).disabled(model.exporting)
                    .help("Close without exporting (Esc)")
                Spacer()
                Button("Export") { model.export() }.keyboardShortcut(.defaultAction).disabled(model.exporting)
                    .help("Export the video with these settings (↩)")
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 346)
        .environment(\.colorScheme, .dark)
    }
}
