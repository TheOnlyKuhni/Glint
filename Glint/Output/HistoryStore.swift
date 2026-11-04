import AppKit

/// Keeps every capture in ~/Library/Application Support/Glint/History for "Capture History" and drag & drop.
/// Each capture has its own folder (so the file keeps its user-facing name) with a small metadata file.
final class HistoryStore {
    static let shared = HistoryStore()

    var lastCapture: CaptureItem?

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Glint/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// One capture in the history.
    struct Entry: Identifiable, Equatable {
        let fileURL: URL
        let date: Date
        /// Bundle id of the app that was in front when it was captured (shown as a badge).
        let sourceApp: String?
        /// A Studio Mode recording (its pointer, keys and camera are kept next to it, so it stays editable).
        var isProject = false
        var id: URL { fileURL }
        var isVideo: Bool { ["mp4", "mov", "m4v"].contains(fileURL.pathExtension.lowercased()) }
        var isGIF: Bool { fileURL.pathExtension.lowercased() == "gif" }
        var folder: URL { fileURL.deletingLastPathComponent() }
    }

    private struct Metadata: Codable { var sourceApp: String? }
    private static let metadataName = ".glint.json"

    func newFileURL(name: String, ext: String, sourceApp: String? = nil) -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let sourceApp, let data = try? JSONEncoder().encode(Metadata(sourceApp: sourceApp)) {
            try? data.write(to: folder.appendingPathComponent(Self.metadataName))
        }
        return folder.appendingPathComponent(name).appendingPathExtension(ext)
    }

    /// Every capture, newest first.
    func entries() -> [Entry] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder -> Entry? in
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            let kinds = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mp4", "mov", "m4v"]
            guard let file = files.first(where: { kinds.contains($0.pathExtension.lowercased()) }) else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let meta = (try? Data(contentsOf: folder.appendingPathComponent(Self.metadataName)))
                .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
            let isProject = fm.fileExists(atPath: StudioRecording.folder(for: file).appendingPathComponent("studio.json").path)
            return Entry(fileURL: file, date: date, sourceApp: meta?.sourceApp, isProject: isProject)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.folder)
        if lastCapture?.fileURL == entry.fileURL { lastCapture = nil }
    }

    func clear() {
        entries().forEach(delete)
        lastCapture = nil
    }

    /// Deletes captures older than the "Keep history" setting (0 = forever, -1 = never keep).
    func prune() {
        let days = Defaults[Prefs.historyDays]
        guard days != 0 else { return }
        // "Never" still keeps the last hour, so open overlays and editors keep their files.
        let age: TimeInterval = days < 0 ? 3600 : Double(days) * 86_400
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries() where entry.date < cutoff && !QuickAccessManager.shared.isShowing(entry.fileURL) { delete(entry) }
    }
}
