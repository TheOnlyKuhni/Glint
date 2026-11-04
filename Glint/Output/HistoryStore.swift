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

    /// Removed captures wait here, in the same folders, until the Trash is emptied.
    let trashDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Glint/Trash", isDirectory: true)
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
        /// When it was moved to the Trash (nil outside it).
        var trashedAt: Date?
        var id: URL { fileURL }
        var isVideo: Bool { ["mp4", "mov", "m4v"].contains(fileURL.pathExtension.lowercased()) }
        var isGIF: Bool { fileURL.pathExtension.lowercased() == "gif" }
        var folder: URL { fileURL.deletingLastPathComponent() }
    }

    private struct Metadata: Codable {
        var sourceApp: String?
        /// When it was moved to the Trash.
        var trashedAt: Date?
    }
    private static let metadataName = ".glint.json"

    func newFileURL(name: String, ext: String, sourceApp: String? = nil) -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let sourceApp, let data = try? JSONEncoder().encode(Metadata(sourceApp: sourceApp)) {
            try? data.write(to: folder.appendingPathComponent(Self.metadataName))
        }
        return folder.appendingPathComponent(name).appendingPathExtension(ext)
    }

    private func metadata(in folder: URL) -> Metadata? {
        (try? Data(contentsOf: folder.appendingPathComponent(Self.metadataName))).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
    }

    private func write(_ metadata: Metadata, to folder: URL) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: folder.appendingPathComponent(Self.metadataName))
    }

    /// Every capture (or every one in the Trash), newest first.
    func entries(inTrash: Bool = false) -> [Entry] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: inTrash ? trashDirectory : directory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return folders.compactMap { folder -> Entry? in
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            let kinds = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mp4", "mov", "m4v"]
            guard let file = files.first(where: { kinds.contains($0.pathExtension.lowercased()) }) else { return nil }
            let date = (try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let meta = metadata(in: folder)
            let isProject = fm.fileExists(atPath: StudioRecording.folder(for: file).appendingPathComponent("studio.json").path)
            return Entry(fileURL: file, date: date, sourceApp: meta?.sourceApp, isProject: isProject, trashedAt: meta?.trashedAt)
        }
        .sorted { ($0.trashedAt ?? $0.date) > ($1.trashedAt ?? $1.date) }
    }

    var trashCount: Int { entries(inTrash: true).count }

    /// Removes a capture from the history: it goes to the Trash.
    func moveToTrash(_ entry: Entry) {
        QuickAccessManager.shared.close(file: entry.fileURL)
        var meta = metadata(in: entry.folder) ?? Metadata()
        meta.trashedAt = Date()
        write(meta, to: entry.folder)
        do { try FileManager.default.moveItem(at: entry.folder, to: trashDirectory.appendingPathComponent(entry.folder.lastPathComponent, isDirectory: true)) } catch {
            glintLog("couldn't move to the Trash: \(error)")
            NSSound.beep()
            return
        }
        if lastCapture?.fileURL == entry.fileURL { lastCapture = nil }
    }

    /// Puts a capture from the Trash back into the history. One past "Keep history" counts as new, or the next
    /// cleanup would take it again.
    func putBack(_ entry: Entry) {
        var meta = metadata(in: entry.folder) ?? Metadata()
        meta.trashedAt = nil
        write(meta, to: entry.folder)
        let target = directory.appendingPathComponent(entry.folder.lastPathComponent, isDirectory: true)
        do { try FileManager.default.moveItem(at: entry.folder, to: target) } catch {
            glintLog("couldn't put back: \(error)")
            NSSound.beep()
            return
        }
        if let cutoff = keepCutoff, entry.date < cutoff {
            try? FileManager.default.setAttributes([.creationDate: Date()], ofItemAtPath: target.path)
        }
    }

    /// Deletes a capture for good.
    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.folder)
        if lastCapture?.fileURL == entry.fileURL { lastCapture = nil }
    }

    /// "Clear History": everything goes to the Trash.
    func clear() {
        entries().forEach(moveToTrash)
        lastCapture = nil
    }

    func emptyTrash() { entries(inTrash: true).forEach(delete) }

    /// What's older than this leaves the history ("Keep history": 0 = forever, -1 = never keep).
    private var keepCutoff: Date? {
        let days = Defaults[Prefs.historyDays]
        guard days != 0 else { return nil }
        // "Never" still keeps the last hour, so open overlays and editors keep their files.
        return Date().addingTimeInterval(days < 0 ? -3600 : -Double(days) * 86_400)
    }

    /// Deletes captures older than the "Keep history" setting and what's been in the Trash longer than its setting.
    /// Those captures expired by the setting, nobody removed them: they don't go through the Trash.
    func prune() {
        if let cutoff = keepCutoff {
            for entry in entries() where entry.date < cutoff && !QuickAccessManager.shared.isShowing(entry.fileURL) { delete(entry) }
        }
        let days = Defaults[Prefs.trashDays]
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for entry in entries(inTrash: true) where (entry.trashedAt ?? .distantPast) < cutoff { delete(entry) }
    }
}
