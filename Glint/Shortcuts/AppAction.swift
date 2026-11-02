import Foundation

/// Every user-triggerable command. Used by global shortcuts, the menu bar menu and the URL scheme.
enum AppAction: String, CaseIterable, Identifiable {
    // General
    case allInOne, toggleDesktopIcons, openHistory, restoreLastCapture
    // Screenshots
    case captureArea, capturePreviousArea, captureFullscreen, captureWindow, selfTimer
    case captureAreaCopy, captureAreaSave, captureAreaAnnotate, captureAreaPin
    // Screen Recording
    case recordScreen, recordStudio, pauseRecording, restartRecording, toggleCameraFullscreen
    // Scrolling Capture
    case scrollingCapture
    // OCR
    case captureText, captureTextWithLineBreaks, captureTextWithoutLineBreaks
    // Quick Access Overlay
    case toggleOverlays, saveAllOverlays, closeAllOverlays
    // Pin
    case pinImage, togglePins, closeAllPins, pinLastScreenshot
    // Annotate
    case annotateFile, annotateClipboard, annotateLastScreenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allInOne: "All-In-One"
        case .toggleDesktopIcons: "Toggle Desktop Icons"
        case .openHistory: "Open Capture History"
        case .restoreLastCapture: "Restore Last Capture"
        case .captureArea: "Capture Area"
        case .capturePreviousArea: "Capture Previous Area"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureWindow: "Capture Window"
        case .selfTimer: "Timer"
        case .captureAreaCopy: "Capture Area & Copy to Clipboard"
        case .captureAreaSave: "Capture Area & Save"
        case .captureAreaAnnotate: "Capture Area & Annotate"
        case .captureAreaPin: "Capture Area & Pin to the Screen"
        case .recordScreen: "Record Screen / Stop Recording"
        case .recordStudio: "Start Studio Mode Recording"
        case .pauseRecording: "Pause/Resume Recording"
        case .restartRecording: "Restart Recording"
        case .toggleCameraFullscreen: "Toggle Camera Fullscreen"
        case .scrollingCapture: "Scrolling Capture"
        case .captureText: "Capture Text"
        case .captureTextWithLineBreaks: "Capture Text With Line Breaks"
        case .captureTextWithoutLineBreaks: "Capture Text Without Line Breaks"
        case .toggleOverlays: "Hide/Show Overlays"
        case .saveAllOverlays: "Save All Overlays"
        case .closeAllOverlays: "Close All Overlays"
        case .pinImage: "Choose and Pin an Image"
        case .togglePins: "Toggle Pins Visibility"
        case .closeAllPins: "Close All Pins"
        case .pinLastScreenshot: "Pin Last Screenshot"
        case .annotateFile: "Open File"
        case .annotateClipboard: "Open From Clipboard"
        case .annotateLastScreenshot: "Annotate Last Screenshot"
        }
    }

    /// The standard macOS screenshot shortcuts (the system ones must be turned off in System Settings).
    var defaultShortcut: KeyCombo? {
        switch self {
        case .captureFullscreen: KeyCombo(key: .three, modifiers: [.shift, .command])
        case .captureArea: KeyCombo(key: .four, modifiers: [.shift, .command])
        case .allInOne: KeyCombo(key: .five, modifiers: [.shift, .command])
        case .captureAreaCopy: KeyCombo(key: .four, modifiers: [.control, .shift, .command])
        default: nil
        }
    }

    /// URL scheme command, e.g. `glint://capture-area`.
    var urlCommand: String {
        rawValue.reduce(into: "") { result, ch in
            if ch.isUppercase { result += "-" + ch.lowercased() } else { result.append(ch) }
        }
    }
}

struct ShortcutSection: Identifiable {
    let title: String
    let symbol: String
    let groups: [[AppAction]]
    var id: String { title }

    static let all: [ShortcutSection] = [
        .init(title: "General", symbol: "gearshape.fill",
              groups: [[.allInOne, .toggleDesktopIcons, .openHistory, .restoreLastCapture]]),
        .init(title: "Screenshots", symbol: "camera.fill",
              groups: [[.captureArea, .capturePreviousArea, .captureFullscreen, .captureWindow, .selfTimer],
                       [.captureAreaCopy, .captureAreaSave, .captureAreaAnnotate, .captureAreaPin]]),
        .init(title: "Screen Recording", symbol: "video.fill",
              groups: [[.recordScreen, .recordStudio, .pauseRecording, .restartRecording, .toggleCameraFullscreen]]),
        .init(title: "Scrolling Capture", symbol: "computermouse.fill", groups: [[.scrollingCapture]]),
        .init(title: "OCR", symbol: "text.viewfinder",
              groups: [[.captureText, .captureTextWithLineBreaks, .captureTextWithoutLineBreaks]]),
        .init(title: "Quick Access Overlay", symbol: "rectangle.on.rectangle",
              groups: [[.toggleOverlays, .saveAllOverlays, .closeAllOverlays]]),
        .init(title: "Pin", symbol: "pin.fill",
              groups: [[.pinImage, .togglePins, .closeAllPins, .pinLastScreenshot]]),
        .init(title: "Annotate", symbol: "square.and.pencil",
              groups: [[.annotateFile, .annotateClipboard, .annotateLastScreenshot]]),
    ]
}
