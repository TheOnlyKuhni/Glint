import Foundation

/// Answers for the `glint` command-line tool (`Glint.app/Contents/Resources/glint`). The tool adds `reply=<id>` to the
/// link it sends; Glint writes one answer to `<user temp dir>/glint-cli/<id>` once the command is done:
///
///     file <path>        a capture or recording was stored (its Capture History file)
///     text <text>        Capture Text copied this (may span lines)
///     recording          a recording started (stop it with the same command)
///     ok                 any other command ran
///     cancelled          the selection was cancelled
///     busy               another capture is still running
///     error <message>
///
/// Only an id of letters, digits and dashes is accepted, and the folder is fixed, so a link can't make Glint write
/// anywhere else.
enum CLIReply {
    private static var pending: String?

    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("glint-cli", isDirectory: true) }

    /// Commands that answer later (with a file, text, a cancel…), not right after they run.
    static func answersLater(_ action: AppAction) -> Bool {
        switch action {
        case .captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer,
             .captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin,
             .recordScreen, .recordStudio, .scrollingCapture, .allInOne,
             .captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks: true
        default: false
        }
    }

    /// Starts waiting for the answer to a link with `reply=<id>`; a newer command takes over.
    static func begin(_ id: String?) {
        guard let id, id.count <= 64, !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            pending = nil
            return
        }
        pending = id
    }

    static var isWaiting: Bool { pending != nil }

    static func delivered(_ file: URL) { send("file \(file.path)") }
    static func cancelled() { send("cancelled") }
    static func error(_ message: String) { send("error \(message)") }

    /// Writes the answer, once, and stops waiting.
    static func send(_ line: String) {
        guard let id = pending else { return }
        pending = nil
        glintLog("cli reply \(id.prefix(8)): \(line.prefix(80))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(id)
        let temp = folder.appendingPathComponent(".\(id).tmp")
        do {
            try Data((line + "\n").utf8).write(to: temp)
            _ = try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)  // the tool never reads half an answer
        } catch {
            glintLog("cli reply failed: \(error)")
        }
    }
}
