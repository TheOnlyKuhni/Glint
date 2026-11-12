import AppKit
import ServiceManagement

/// "Uninstall Glint…": removes everything Glint stores outside the folders you save captures to, resets its privacy
/// permissions, moves the app to the Trash and quits. Saved screenshots and recordings are left alone.
/// Keep the list in sync with `Tools/uninstall.sh` and the Homebrew cask's `zap` stanza.
enum Uninstaller {
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.philippk.glint" }

    /// Folders and files in ~/Library that belong to Glint.
    static var libraryItems: [String] {
        [
            "Application Support/Glint",
            "Logs/Glint",
            "Caches/\(bundleID)",
            "HTTPStorages/\(bundleID)",
            "HTTPStorages/\(bundleID).binarycookies",
            "WebKit/\(bundleID)",
            "Saved Application State/\(bundleID).savedState",
            "Preferences/\(bundleID).plist",
        ]
    }

    static func confirmAndRun() {
        NSApp.bringToFront()
        let alert = NSAlert()
        alert.messageText = "Uninstall Glint?"
        alert.informativeText = """
            Glint will delete its settings, Capture History, saved edits and logs, turn off Launch at Login, reset its \
            permissions, move itself to the Trash and quit.

            Screenshots and recordings you saved to your folders stay where they are. The "Glint Focus On/Off" \
            shortcuts (if you added them) can be removed in the Shortcuts app.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run()
    }

    private static func run() {
        glintLog("uninstall")
        try? SMAppService.mainApp.unregister()
        for permission in ["ScreenCapture", "Microphone", "Camera", "Accessibility", "ListenEvent"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", permission, bundleID]
            try? process.run()
            process.waitUntilExit()
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for item in libraryItems { try? FileManager.default.removeItem(at: library.appendingPathComponent(item)) }
        // The command line tool's link, when /usr/local/bin lets us (it usually needs an administrator).
        let link = CommandLineTool.link.path
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link), dest.contains("Glint.app/") {
            try? FileManager.default.removeItem(atPath: link)
        }
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
