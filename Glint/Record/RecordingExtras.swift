import AppKit
import AVFoundation

/// "Audio tracks: Single track": a recording keeps microphone and system audio on separate tracks while it records;
/// afterwards they are mixed into one AAC track. The video is copied as is (no re-encoding).
enum AudioMixdown {
    /// The movie with its audio tracks mixed into one, or nil when there's nothing to mix (or it failed).
    nonisolated static func singleTrack(_ movie: URL) async -> URL? {
        let asset = AVURLAsset(url: movie)
        guard let audio = try? await asset.loadTracks(withMediaType: .audio), audio.count > 1,
              let video = try? await asset.loadTracks(withMediaType: .video).first,
              let videoFormat = try? await video.load(.formatDescriptions).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = movie.deletingPathExtension().appendingPathExtension("mixed.mp4")
        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return nil }

        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        let channels = Defaults[Prefs.recMono] ? 1 : 2
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(videoOut), reader.canAdd(audioOut) else { return nil }
        reader.add(videoOut)
        reader.add(audioOut)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoIn.transform = (try? await video.load(.preferredTransform)) ?? .identity
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 192_000,
        ])
        writer.add(videoIn)
        writer.add(audioIn)
        guard reader.startReading(), writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (input, source, label) in [(videoIn, videoOut as AVAssetReaderOutput, "video"), (audioIn, audioOut, "audio")] {
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        input.requestMediaDataWhenReady(on: DispatchQueue(label: "com.philippk.glint.mixdown.\(label)")) {
                            while input.isReadyForMoreMediaData {
                                guard let buffer = source.copyNextSampleBuffer() else {
                                    input.markAsFinished()
                                    cont.resume()
                                    return
                                }
                                input.append(buffer)
                            }
                        }
                    }
                }
            }
        }
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            glintLog("audio mixdown failed: \(String(describing: writer.error ?? reader.error))")
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }
}

/// "Do Not Disturb while recording". macOS gives apps no way to switch Focus (the private DoNotDisturb framework
/// rejects apps without Apple's entitlement), so Glint does what other tools do: it builds two one-action Shortcuts
/// ("Set Focus: Do Not Disturb on/off"), signs them with `shortcuts sign` and hands them to the Shortcuts app, where
/// the user clicks "Add Shortcut" once each. Recordings then run them via `/usr/bin/shortcuts run`.
enum DoNotDisturb {
    static let onShortcut = "Glint Focus On"
    static let offShortcut = "Glint Focus Off"
    private static var turnedOn = false

    /// Whether both shortcuts exist.
    static func isSetUp() async -> Bool {
        let names = await run(["list"]).split(separator: "\n").map(String.init)
        return names.contains(onShortcut) && names.contains(offShortcut)
    }

    static func begin() {
        guard Defaults[Prefs.recDoNotDisturb] else { return }
        Task {
            guard await isSetUp() else { glintLog("dnd: shortcuts missing"); return }
            _ = await run(["run", onShortcut])
            turnedOn = true
        }
    }

    static func end() {
        guard turnedOn else { return }
        turnedOn = false
        Task { _ = await run(["run", offShortcut]) }
    }

    /// Asks once and installs the two shortcuts (from Settings when the option is switched on).
    static func offerSetup() {
        let alert = NSAlert()
        alert.messageText = "Add the Do Not Disturb shortcuts?"
        alert.informativeText = "macOS lets apps switch Focus only through Shortcuts. Glint adds two small shortcuts, “\(onShortcut)” and “\(offShortcut)”, and runs them when a recording starts and ends. Click “Add Shortcut” for each in the Shortcuts app."
        alert.addButton(withTitle: "Add Shortcuts")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            for (name, on) in [(onShortcut, true), (offShortcut, false)] {
                guard let file = await makeShortcut(name: name, enable: on) else { NSSound.beep(); return }
                NSWorkspace.shared.open(file)
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    /// A signed `.shortcut` with one "Set Focus" action (Do Not Disturb, on or off).
    private static func makeShortcut(name: String, enable: Bool) async -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GlintShortcuts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unsigned = dir.appendingPathComponent("\(name).unsigned.shortcut"), signed = dir.appendingPathComponent("\(name).shortcut")
        let workflow: [String: Any] = [
            "WFWorkflowMinimumClientVersion": 900, "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 4_292_093_695, "WFWorkflowIconGlyphNumber": 59446],
            "WFWorkflowImportQuestions": [], "WFWorkflowInputContentItemClasses": [], "WFWorkflowOutputContentItemClasses": [],
            "WFWorkflowTypes": [], "WFQuickActionSurfaces": [],
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": "is.workflow.actions.dnd.set",
                "WFWorkflowActionParameters": [
                    "Enabled": enable ? 1 : 0, "Operation": "Turn",
                    "FocusModes": ["Identifier": "com.apple.donotdisturb.mode.default", "DisplayString": "Do Not Disturb"],
                ],
            ]],
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: workflow, format: .binary, options: 0),
              (try? data.write(to: unsigned)) != nil else { return nil }
        try? FileManager.default.removeItem(at: signed)
        _ = await run(["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path])
        return FileManager.default.fileExists(atPath: signed.path) ? signed : nil
    }

    private static func run(_ arguments: [String]) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}
