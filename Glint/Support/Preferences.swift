import SwiftUI

/// A typed UserDefaults key with its default value.
struct Pref<Value> {
    let key: String
    let defaultValue: Value
}

/// Typed access to preferences from non-SwiftUI code: `Defaults[Prefs.playSounds]`.
enum Defaults {
    static subscript<V>(_ pref: Pref<V>) -> V {
        get { UserDefaults.standard.object(forKey: pref.key) as? V ?? pref.defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: pref.key) }
    }

    static subscript<V: RawRepresentable>(_ pref: Pref<V>) -> V where V.RawValue == String {
        get { UserDefaults.standard.string(forKey: pref.key).flatMap(V.init(rawValue:)) ?? pref.defaultValue }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: pref.key) }
    }
}

extension AppStorage {
    init(_ pref: Pref<Value>) where Value == Bool { self.init(wrappedValue: pref.defaultValue, pref.key) }
    init(_ pref: Pref<Value>) where Value == Int { self.init(wrappedValue: pref.defaultValue, pref.key) }
    init(_ pref: Pref<Value>) where Value == Double { self.init(wrappedValue: pref.defaultValue, pref.key) }
    init(_ pref: Pref<Value>) where Value == String { self.init(wrappedValue: pref.defaultValue, pref.key) }
    init(_ pref: Pref<Value>) where Value: RawRepresentable, Value.RawValue == String {
        self.init(wrappedValue: pref.defaultValue, pref.key)
    }
}

enum Prefs {
    // MARK: General
    static let launchAtLogin = Pref(key: "launchAtLogin", defaultValue: false)
    static let showMenuBarIcon = Pref(key: "showMenuBarIcon", defaultValue: true)
    static let hideDesktopIconsWhileCapturing = Pref(key: "hideDesktopIconsWhileCapturing", defaultValue: false)
    static let playSounds = Pref(key: "playSounds", defaultValue: true)
    static let shutterSound = Pref(key: "shutterSound", defaultValue: ShutterSound.systemDefault)
    /// Empty means the Desktop.
    static let exportLocation = Pref(key: "exportLocation", defaultValue: "")

    static func afterCapture(_ action: AfterCaptureAction, _ kind: CaptureKind) -> Pref<Bool> {
        Pref(key: "afterCapture.\(action.rawValue).\(kind.rawValue)", defaultValue: action == .showQuickAccess)
    }

    // MARK: Quick Access
    static let quickAccessPosition = Pref(key: "quickAccess.position", defaultValue: ScreenSide.left)
    static let quickAccessMoveToActiveScreen = Pref(key: "quickAccess.moveToActiveScreen", defaultValue: true)
    /// 0...4, five steps like the slider in settings.
    static let quickAccessSize = Pref(key: "quickAccess.size", defaultValue: 2.0)
    static let quickAccessAutoClose = Pref(key: "quickAccess.autoClose", defaultValue: false)
    static let quickAccessAutoCloseAction = Pref(key: "quickAccess.autoCloseAction", defaultValue: AutoCloseAction.saveAndClose)
    static let quickAccessAutoCloseInterval = Pref(key: "quickAccess.autoCloseInterval", defaultValue: 30)
    static let quickAccessCloseAfterDragging = Pref(key: "quickAccess.closeAfterDragging", defaultValue: true)
    static let quickAccessSaveBehavior = Pref(key: "quickAccess.saveBehavior", defaultValue: SaveButtonBehavior.exportLocation)

    // MARK: Wallpaper
    static let wallpaperSource = Pref(key: "wallpaper.source", defaultValue: WallpaperSource.desktop)
    static let wallpaperCustomPath = Pref(key: "wallpaper.customPath", defaultValue: "")
    static let wallpaperColor = Pref(key: "wallpaper.color", defaultValue: "#1E3A8A")
    static let wallpaperUpdateOnSpaceSwitch = Pref(key: "wallpaper.updateOnSpaceSwitch", defaultValue: true)

    // MARK: Screenshots
    static let fileFormat = Pref(key: "screenshots.format", defaultValue: ImageFormat.png)
    /// Index into BackgroundStyle.presets applied to every screenshot; -1 = none.
    static let backgroundPreset = Pref(key: "screenshots.backgroundPreset", defaultValue: -1)
    static let convertToSRGB = Pref(key: "screenshots.convertToSRGB", defaultValue: false)
    static let scaleRetinaTo1x = Pref(key: "screenshots.scaleTo1x", defaultValue: false)
    static let addBorder = Pref(key: "screenshots.addBorder", defaultValue: false)
    static let selfTimerInterval = Pref(key: "screenshots.selfTimerInterval", defaultValue: 5)
    static let showCursor = Pref(key: "screenshots.showCursor", defaultValue: false)
    static let freezeScreen = Pref(key: "screenshots.freezeScreen", defaultValue: false)
    static let windowBackground = Pref(key: "screenshots.windowBackground", defaultValue: WindowBackground.wallpaper)
    /// 0...6, seven steps like the slider in settings.
    static let windowPadding = Pref(key: "screenshots.windowPadding", defaultValue: 2.0)
    static let windowShadow = Pref(key: "screenshots.windowShadow", defaultValue: true)
    static let crosshairMode = Pref(key: "screenshots.crosshairMode", defaultValue: CrosshairMode.disabled)
    static let showMagnifier = Pref(key: "screenshots.showMagnifier", defaultValue: false)

    // MARK: Screen Recording
    static let recShowControls = Pref(key: "rec.showControls", defaultValue: true)
    static let recRememberSelection = Pref(key: "rec.rememberSelection", defaultValue: false)
    static let recTimeInMenuBar = Pref(key: "rec.timeInMenuBar", defaultValue: true)
    static let recDimScreen = Pref(key: "rec.dimScreen", defaultValue: true)
    static let recCountdown = Pref(key: "rec.countdown", defaultValue: true)
    static let recDoNotDisturb = Pref(key: "rec.doNotDisturb", defaultValue: false)
    static let recShowCursor = Pref(key: "rec.showCursor", defaultValue: true)
    static let recHighlightClicks = Pref(key: "rec.highlightClicks", defaultValue: false)
    static let recShowKeystrokes = Pref(key: "rec.showKeystrokes", defaultValue: false)
    /// Which keys show (`KeystrokeFilter`; read through `KeystrokeFilter.setting`, which knows the older
    /// `recKeysShortcutsOnly`), and the keys never shown (JSON of `[ExcludedKey]`). New Studio projects start with these.
    static let recKeysFilter = Pref(key: "rec.keysFilter", defaultValue: "all")
    static let recKeysExcluded = Pref(key: "rec.keysExcluded", defaultValue: "")
    /// Studio Mode's automatic zooms (`AutoZoomSettings`): whether a new recording gets them, what starts one, and
    /// how they look (level, seconds before and after the action, shortest zoom, gap below which two join).
    /// The video editor's timeline shows the recording's own frames instead of the edited ones.
    static let editorRawFrames = Pref(key: "editor.rawFrames", defaultValue: false)
    static let studioAutoZoom = Pref(key: "studio.autoZoom", defaultValue: true)
    static let studioZoomClicks = Pref(key: "studio.zoomClicks", defaultValue: true)
    static let studioZoomRightClicks = Pref(key: "studio.zoomRightClicks", defaultValue: false)
    static let studioZoomDrags = Pref(key: "studio.zoomDrags", defaultValue: true)
    static let studioZoomTyping = Pref(key: "studio.zoomTyping", defaultValue: true)
    static let studioZoomScrolling = Pref(key: "studio.zoomScrolling", defaultValue: false)
    static let studioZoomLevel = Pref(key: "studio.zoomLevel", defaultValue: 1.8)
    static let studioZoomBefore = Pref(key: "studio.zoomBefore", defaultValue: 0.6)
    static let studioZoomAfter = Pref(key: "studio.zoomAfter", defaultValue: 1.6)
    static let studioZoomMinLength = Pref(key: "studio.zoomMinLength", defaultValue: 2.0)
    static let studioZoomJoin = Pref(key: "studio.zoomJoin", defaultValue: 1.0)
    static let studioZoomFollow = Pref(key: "studio.zoomFollow", defaultValue: true)
    /// Recording panel toggles.
    /// Microphone to record (AVCaptureDevice unique ID); empty = "Do Not Record Microphone".
    static let recMicDevice = Pref(key: "rec.micDevice", defaultValue: "")
    /// Aspect ratio of the recording area ("16:9" …); empty = Freeform.
    static let recRatio = Pref(key: "rec.ratio", defaultValue: "")
    /// Webcam overlay: camera unique ID (empty = none), size, shape, mirrored.
    static let recCamera = Pref(key: "rec.camera", defaultValue: "")
    static let recCameraSize = Pref(key: "rec.cameraSize", defaultValue: 1)
    static let recCameraShape = Pref(key: "rec.cameraShape", defaultValue: 1)
    static let recCameraFlip = Pref(key: "rec.cameraFlip", defaultValue: true)
    static let recLastArea = Pref(key: "rec.lastArea", defaultValue: "")
    static let recConfirmClose = Pref(key: "rec.confirmClose", defaultValue: true)
    static let scrollingTutorialSeen = Pref(key: "scrolling.tutorialSeen", defaultValue: false)
    static let recFrameRate = Pref(key: "rec.frameRate", defaultValue: 60)
    static let recMaxResolution = Pref(key: "rec.maxResolution", defaultValue: MaxResolution.original)
    static let recScaleTo1x = Pref(key: "rec.scaleTo1x", defaultValue: false)
    static let recMono = Pref(key: "rec.mono", defaultValue: false)
    static let recSystemAudio = Pref(key: "rec.systemAudio", defaultValue: false)
    static let recAudioTracks = Pref(key: "rec.audioTracks", defaultValue: AudioTracks.single)
    static let gifFrameRate = Pref(key: "gif.frameRate", defaultValue: 15)
    static let gifResolution = Pref(key: "gif.resolution", defaultValue: 800)
    static let gifOptimize = Pref(key: "gif.optimize", defaultValue: true)
    static let gifQuality = Pref(key: "gif.quality", defaultValue: 0.5)

    // MARK: Annotate
    static let annotateInverseArrow = Pref(key: "annotate.inverseArrow", defaultValue: false)
    static let annotateSmoothDrawing = Pref(key: "annotate.smoothDrawing", defaultValue: true)
    static let annotateRememberBackground = Pref(key: "annotate.rememberBackground", defaultValue: true)
    static let annotateShadow = Pref(key: "annotate.shadow", defaultValue: true)
    static let annotateExpandCanvas = Pref(key: "annotate.expandCanvas", defaultValue: true)
    /// "Lock canvas" (bottom bar): drawing never grabs an object it starts on, whatever the tool.
    static let annotateLockCanvas = Pref(key: "annotate.lockCanvas", defaultValue: true)
    /// Off (the default): a placed object stays unselected, so the next click draws again.
    static let annotateSelectPlaced = Pref(key: "annotate.selectPlaced", defaultValue: false)
    static let annotateAlwaysOnTop = Pref(key: "annotate.alwaysOnTop", defaultValue: false)
    static let annotateShowDockIcon = Pref(key: "annotate.showDockIcon", defaultValue: true)

    // MARK: Advanced
    static let askForName = Pref(key: "advanced.askForName", defaultValue: false)
    static let fileNameFormat = Pref(key: "advanced.fileNameFormat", defaultValue: "Glint {yyyy}-{MM}-{dd} at {HH}.{mm}.{ss}")
    static let add2xSuffix = Pref(key: "advanced.add2xSuffix", defaultValue: false)
    static let clipboardMode = Pref(key: "advanced.clipboardMode", defaultValue: ClipboardMode.fileAndImage)
    static let historyDays = Pref(key: "advanced.historyDays", defaultValue: 3)
    /// Capture Text language: "auto" (the system languages) or one recognizer language code.
    static let ocrLanguage = Pref(key: "advanced.ocrLanguage", defaultValue: "auto")
    static let ocrKeepLineBreaks = Pref(key: "advanced.ocrKeepLineBreaks", defaultValue: true)
    static let ocrDetectLinks = Pref(key: "advanced.ocrDetectLinks", defaultValue: true)
    /// Keeps bullets ("-"), numbering ("1.") and indentation of lists (with line breaks kept).
    static let ocrKeepLists = Pref(key: "advanced.ocrKeepLists", defaultValue: true)
    /// Capture Text: when a QR code is found, copy the surrounding text too (otherwise only the code's content).
    static let ocrCopyTextWithQR = Pref(key: "advanced.ocrCopyTextWithQR", defaultValue: false)
    static let recClickColor = Pref(key: "rec.clickColor", defaultValue: "3478F6")
    static let recClickSize = Pref(key: "rec.clickSize", defaultValue: 1.0)
    static let recClickFilled = Pref(key: "rec.clickFilled", defaultValue: false)
    static let recKeysPosition = Pref(key: "rec.keysPosition", defaultValue: "bottom")
    static let recKeysSize = Pref(key: "rec.keysSize", defaultValue: 1)
    static let recKeysDuration = Pref(key: "rec.keysDuration", defaultValue: 1.5)
    static let recKeysShortcutsOnly = Pref(key: "rec.keysShortcutsOnly", defaultValue: false)
    static let allInOneRememberSelection = Pref(key: "advanced.allInOneRememberSelection", defaultValue: true)
    /// All-In-One's last area (CG rect string) and aspect ratio key ("" = freeform).
    static let allInOneLastArea = Pref(key: "aio.lastArea", defaultValue: "")
    static let allInOneRatio = Pref(key: "aio.ratio", defaultValue: "")
    static let pinRoundedCorners = Pref(key: "advanced.pinRoundedCorners", defaultValue: true)
    static let pinShadow = Pref(key: "advanced.pinShadow", defaultValue: true)
    static let pinBorder = Pref(key: "advanced.pinBorder", defaultValue: true)
    static let allowURLScheme = Pref(key: "advanced.allowURLScheme", defaultValue: true)

    // MARK: State
    static let lastAreaRect = Pref(key: "state.lastAreaRect", defaultValue: "")
}

// MARK: - Option types

enum CaptureKind: String { case screenshot, recording }

enum AfterCaptureAction: String, CaseIterable, Identifiable {
    case showQuickAccess, copyToClipboard, save, openAnnotate, pin, openVideoEditor
    var id: String { rawValue }

    var title: String {
        switch self {
        case .showQuickAccess: "Show Quick Access Overlay"
        case .copyToClipboard: "Copy file to clipboard"
        case .save: "Save"
        case .openAnnotate: "Open Annotate tool"
        case .pin: "Pin to the screen"
        case .openVideoEditor: "Open Video Editor"
        }
    }

    func applies(to kind: CaptureKind) -> Bool {
        switch self {
        case .openAnnotate, .pin: kind == .screenshot
        case .openVideoEditor: kind == .recording
        default: true
        }
    }
}

enum ShutterSound: String, CaseIterable, Identifiable {
    case systemDefault, grab, shutter, pop, tink
    var id: String { rawValue }
    var title: String {
        switch self {
        case .systemDefault: "System Default"
        case .grab: "Grab"
        case .shutter: "Shutter"
        case .pop: "Pop"
        case .tink: "Tink"
        }
    }
}

enum ScreenSide: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
}

enum AutoCloseAction: String, CaseIterable, Identifiable {
    case saveAndClose, close
    var id: String { rawValue }
    var title: String { self == .saveAndClose ? "Save and Close" : "Close" }
}

enum SaveButtonBehavior: String, CaseIterable, Identifiable {
    case exportLocation, ask
    var id: String { rawValue }
    var title: String { self == .exportLocation ? "Save to \"Export location\"" : "Ask where to save" }
}

enum WallpaperSource: String, CaseIterable, Identifiable {
    case desktop, custom, color
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktop: "Desktop wallpaper"
        case .custom: "Custom image"
        case .color: "Solid color"
        }
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg, heic
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

enum WindowBackground: String { case wallpaper, transparent }

enum CrosshairMode: String, CaseIterable, Identifiable {
    case disabled, always, holdingShift
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disabled: "Disabled"
        case .always: "Always"
        case .holdingShift: "While holding ⌘"
        }
    }
}

enum MaxResolution: String, CaseIterable, Identifiable {
    case original, p2160, p1440, p1080, p720
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original"
        case .p2160: "2160p"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }
}

enum AudioTracks: String, CaseIterable, Identifiable {
    case single, separate
    var id: String { rawValue }
    var title: String { self == .single ? "Single track" : "Separate tracks" }
}

enum ClipboardMode: String, CaseIterable, Identifiable {
    case fileAndImage, image, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fileAndImage: "File & Image (default)"
        case .image: "Image only"
        case .file: "File only"
        }
    }
}
