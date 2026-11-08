import AVFoundation
import Speech

/// Turns a video's speech into captions, on the Mac: Apple's SpeechAnalyzer on macOS 26 and later, the older
/// SFSpeechRecognizer (on-device when the language allows) on macOS 15. Both give each word's time.
@MainActor
final class CaptionGenerator: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, downloading(Double), transcribing
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published private(set) var languages: [Locale] = []
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .preparing, .downloading, .transcribing: true
        default: false
        }
    }

    /// The language to use: the last one picked, else the Mac's.
    static var savedLanguage: String {
        // The Mac's language and region, without extras like "@rg=…" (a region override).
        get { UserDefaults.standard.string(forKey: "captions.language") ?? String(Locale.current.identifier.split(separator: "@").first ?? "en_US") }
        set { UserDefaults.standard.set(newValue, forKey: "captions.language") }
    }

    func loadLanguages() {
        guard languages.isEmpty else { return }
        Task {
            let list: [Locale]
            if #available(macOS 26, *) { list = await SpeechTranscriber.supportedLocales } else { list = Array(SFSpeechRecognizer.supportedLocales()) }
            languages = list.sorted { Self.name($0).localizedCaseInsensitiveCompare(Self.name($1)) == .orderedAscending }
        }
    }

    nonisolated static func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Transcribes the project's audio (all of it, or only the microphone's track) and hands back the captions.
    func generate(project: VideoProject, language: String, microphoneOnly: Bool, done: @escaping ([Caption]) -> Void) {
        guard !isBusy else { return }
        phase = .preparing
        let asset = project.asset
        task = Task {
            do {
                let audio = try await CaptionTranscriber.extractAudio(asset, microphoneOnly: microphoneOnly)
                defer { try? FileManager.default.removeItem(at: audio.deletingLastPathComponent()) }
                let locale = Locale(identifier: language)
                let captions: [Caption]
                if #available(macOS 26, *) {
                    captions = try await CaptionTranscriber.transcribe(audio, locale: locale) { [weak self] p in
                        Task { @MainActor in self?.phase = p }
                    }
                } else {
                    phase = .transcribing
                    captions = try await CaptionTranscriber.transcribeLegacy(audio, locale: locale)
                }
                guard !Task.isCancelled else { return }
                phase = captions.isEmpty ? .failed("No speech was found in this video.") : .idle
                if !captions.isEmpty { done(captions) }
            } catch {
                guard !Task.isCancelled else { return }
                glintLog("captions: \(error)")
                phase = .failed((error as? CaptionTranscriber.Failure)?.message ?? error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }
}

nonisolated enum CaptionTranscriber {
    struct Failure: Error { let message: String }

    /// The audio as 16 kHz mono (what speech recognition works with) in a temporary CAF file. Microphone only: the
    /// last audio track, where Glint keeps the microphone when it records it separately.
    static func extractAudio(_ asset: AVAsset, microphoneOnly: Bool) async throws -> URL {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure(message: "This video has no sound.") }
        let used = microphoneOnly && tracks.count > 1 ? [tracks[tracks.count - 1]] : tracks
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: used, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw Failure(message: "Couldn't prepare the audio.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glint-captions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("audio.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard reader.startReading() else { throw reader.error ?? Failure(message: "Couldn't read the audio.") }
        while let sample = output.copyNextSampleBuffer() {
            let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            try file.write(from: buffer)
        }
        if reader.status == .failed { throw reader.error ?? Failure(message: "Couldn't read the audio.") }
        return url
    }

    @available(macOS 26, *)
    static func transcribe(_ audio: URL, locale: Locale, phase: @escaping @Sendable (CaptionGenerator.Phase) -> Void) async throws -> [Caption] {
        guard SpeechTranscriber.isAvailable else { throw Failure(message: "Speech recognition isn't available on this Mac.") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure(message: "\(CaptionGenerator.name(locale)) isn't supported for captions.")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        // The language's speech model, downloaded once.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            phase(.downloading(0))
            let watch = Task {
                while !Task.isCancelled {
                    phase(.downloading(request.progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { watch.cancel() }
            try await request.downloadAndInstall()
        }
        phase(.transcribing)
        let file = try AVAudioFile(forReading: audio)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task {
            var words: [CaptionWord] = []
            for try await result in transcriber.results {
                var sentence: [CaptionWord] = []
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let token = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    add(token, start: range.start.seconds, end: range.end.seconds, to: &sentence)
                }
                // Each result is a stretch of speech: mark its end so captions break there.
                if var last = sentence.popLast() { last.text += "\u{2063}"; sentence.append(last) }
                words += sentence
            }
            return words
        }
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return captions(from: try await collect.value)
    }

    /// macOS 15: the older recognizer, with punctuation, on the Mac where the language allows it.
    static func transcribeLegacy(_ audio: URL, locale: Locale) async throws -> [Caption] {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw Failure(message: "Glint needs Speech Recognition: System Settings → Privacy & Security → Speech Recognition.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw Failure(message: "\(CaptionGenerator.name(locale)) isn't available for captions.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        let segments: [(String, Double, Double)] = try await withCheckedThrowingContinuation { c in
            let once = Once()
            recognizer.recognitionTask(with: request) { result, error in
                if let error { if once.claim() { c.resume(throwing: error) }; return }
                guard let result, result.isFinal else { return }
                let list = result.bestTranscription.segments.map { ($0.substring, $0.timestamp, $0.timestamp + $0.duration) }
                if once.claim() { c.resume(returning: list) }
            }
        }
        var words: [CaptionWord] = []
        for (text, start, end) in segments { add(text, start: start, end: end, to: &words) }
        return captions(from: words)
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// A recognized token: several words share its time; lone punctuation joins the word before it.
    private static func add(_ token: String, start: Double, end: Double, to words: inout [CaptionWord]) {
        let parts = token.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return }
        if parts.count == 1, parts[0].allSatisfy({ $0.isPunctuation }), !words.isEmpty {
            words[words.count - 1].text += parts[0]
            return
        }
        words += Caption.spread(parts, from: start, to: max(end, start + 0.05))
    }

    /// Captions from words: a new one after a sentence ends, a pause of 0.7 s, the end of a recognized stretch, or
    /// 14 words.
    static func captions(from words: [CaptionWord]) -> [Caption] {
        var captions: [Caption] = [], current: [CaptionWord] = []
        for var w in words {
            let endsStretch = w.text.hasSuffix("\u{2063}")
            if endsStretch { w.text.removeLast() }
            if let last = current.last, w.start - last.end > 0.7 { captions.append(Caption(words: current)); current = [] }
            current.append(w)
            let endsSentence = w.text.last.map { ".!?…".contains($0) } ?? false
            if endsSentence || endsStretch || current.count >= 14 { captions.append(Caption(words: current)); current = [] }
        }
        if !current.isEmpty { captions.append(Caption(words: current)) }
        return captions
    }
}
