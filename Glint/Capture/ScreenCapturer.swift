import AppKit
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay, noWindow, permissionDenied
    var errorDescription: String? {
        switch self {
        case .noDisplay: "The display could not be found."
        case .noWindow: "The window could not be found."
        case .permissionDenied: "Screen Recording permission is missing."
        }
    }
}

/// Thin wrapper around ScreenCaptureKit's screenshot API.
enum ScreenCapturer {
    /// Window titles of Glint windows that must stay visible in captures (e.g. the desktop-icon cover).
    static let includedOwnWindowTitle = "GlintDesktopCover"

    /// Glint's own windows that belong in a screenshot like any other app's: the titled, non-panel ones (editors,
    /// Settings, History). Overlays, Quick Access and toolbars are panels or borderless and stay out.
    static var shownOwnWindows: Set<Int> {
        Set(NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) }.map(\.windowNumber))
    }

    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Captures `rect` (global CG coordinates, points) from `screen`, excluding Glint's own overlays.
    static func capture(rect: CGRect, on screen: NSScreen, showCursor: Bool = false) async throws -> CGImage {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.noDisplay
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let shown = shownOwnWindows
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.title != includedOwnWindowTitle && !shown.contains(Int($0.windowID))
        }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.showsCursor = showCursor
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func captureFullscreen(_ screen: NSScreen, showCursor: Bool) async throws -> CGImage {
        try await capture(rect: screen.cgFrame, on: screen, showCursor: showCursor)
    }

    /// Captures a single window, optionally with its drop shadow, on a transparent background.
    static func capture(windowID: CGWindowID, includeShadow: Bool) async throws -> CGImage {
        let content = try await content()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        // With the shadow, the content is bigger than the window: at the window's own size macOS would shrink window +
        // shadow to fit (the window came out at ~78%). So draw unscaled on a canvas with room around it and crop to
        // what's visible.
        let room: CGFloat = includeShadow ? 150 : 0
        config.width = max(1, Int(((filter.contentRect.width + room * 2) * scale).rounded()))
        config.height = max(1, Int(((filter.contentRect.height + room * 2) * scale).rounded()))
        config.scalesToFit = !includeShadow
        config.ignoreShadowsSingleWindow = !includeShadow
        config.shouldBeOpaque = false
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return includeShadow ? (ImageProcessing.croppedToVisible(image) ?? image) : image
    }

    /// Snapshot of every screen, used for "freeze screen" and the magnifier.
    static func snapshotAllScreens() async -> [CGDirectDisplayID: CGImage] {
        var result: [CGDirectDisplayID: CGImage] = [:]
        for screen in NSScreen.screens {
            if let image = try? await captureFullscreen(screen, showCursor: false) { result[screen.displayID] = image }
        }
        return result
    }
}

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns true when capture may proceed; otherwise asks for permission.
    static func ensureScreenRecording() -> Bool {
        if hasScreenRecording { return true }
        CGRequestScreenCaptureAccess()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Glint requires Screen Recording permission"
        alert.informativeText = """
        In order to continue working properly, Glint needs Screen Recording permission.

        Please open the Privacy & Security panel in System Settings and enable Glint in the Screen Recording section.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }
}
