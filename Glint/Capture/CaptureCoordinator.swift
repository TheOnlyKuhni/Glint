import AppKit

/// Runs every capture flow: area, previous area, fullscreen, window, self-timer.
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var activeOverlay: SelectionOverlay?
    private var isBusy = false

    func perform(_ action: AppAction) {
        glintLog("perform \(action.rawValue) busy=\(isBusy)")
        switch action {
        case .captureArea: captureArea()
        case .capturePreviousArea: capturePreviousArea()
        case .captureFullscreen: captureFullscreen()
        case .captureWindow: captureArea(startIn: .window)
        case .selfTimer: captureArea(selfTimer: true)
        case .captureAreaCopy: captureArea(options: .copyOnly)
        case .captureAreaSave: captureArea(options: .saveOnly)
        case .captureAreaAnnotate: captureArea(options: .annotateOnly)
        case .captureAreaPin: captureArea(options: .pinOnly)
        case .toggleDesktopIcons: DesktopIconsHider.shared.toggle()
        case .toggleOverlays: QuickAccessManager.shared.toggleVisibility()
        case .saveAllOverlays: QuickAccessManager.shared.saveAll()
        case .closeAllOverlays: QuickAccessManager.shared.closeAll()
        case .captureText: TextCapture.run()
        case .captureTextWithLineBreaks: TextCapture.run(keepLineBreaks: true)
        case .captureTextWithoutLineBreaks: TextCapture.run(keepLineBreaks: false)
        case .annotateFile: AnnotateWindowController.openFromPanel()
        case .annotateClipboard: AnnotateWindowController.openFromClipboard()
        case .annotateLastScreenshot:
            if let last = HistoryStore.shared.lastCapture { AnnotateWindowController.open(item: last) } else { NSSound.beep() }
        case .restoreLastCapture:
            if let last = HistoryStore.shared.lastCapture { QuickAccessManager.shared.show(last) } else { NSSound.beep() }
        case .openHistory: CaptureHistory.shared.show()
        case .recordScreen: RecordingController.shared.toggle()
        case .pauseRecording: RecordingController.shared.togglePause()
        case .restartRecording: RecordingController.shared.restart()
        case .scrollingCapture: ScrollingCapture.shared.start()
        case .pinImage: PinManager.shared.pinFromPanel()
        case .pinLastScreenshot: PinManager.shared.pinLastScreenshot()
        case .togglePins: PinManager.shared.toggleAll()
        case .closeAllPins: PinManager.shared.closeAll()
        case .allInOne: AllInOne.shared.start()
        case .toggleCameraFullscreen:
            if WebcamOverlay.shared.isVisible { WebcamOverlay.shared.toggleFullScreen() } else { NSSound.beep() }
        default:
            ComingSoon.show(action.title)
        }
    }

    // MARK: Area & window

    func captureArea(startIn mode: SelectionOverlay.Mode = .area, options: AfterCaptureOptions? = nil, selfTimer: Bool = false) {
        guard !isBusy, Permissions.ensureScreenRecording() else { return }
        isBusy = true
        // Glint's own selection for Capture Area, the Timer and Capture Text alike (one cursor and coordinate pill
        // instead of macOS's `screencapture -i`). The Timer's countdown still comes from screencapture -T.
        Task {
            let hideIcons = Defaults[Prefs.hideDesktopIconsWhileCapturing] && !DesktopIconsHider.shared.isHidingIcons
            if hideIcons { await DesktopIconsHider.shared.hideAndWait() }
            let freeze = Defaults[Prefs.freezeScreen]
            let needsSnapshot = freeze || (Defaults[Prefs.showMagnifier] && Defaults[Prefs.crosshairMode] != .disabled)
            let snapshots = needsSnapshot ? await ScreenCapturer.snapshotAllScreens() : [:]

            let overlay = SelectionOverlay(mode: mode, snapshots: snapshots, showsSnapshot: freeze)
            activeOverlay = overlay
            let result = await withCheckedContinuation { cont in overlay.begin { cont.resume(returning: $0) } }
            activeOverlay = nil

            defer {
                if hideIcons { DesktopIconsHider.shared.show(animated: false) }
                isBusy = false
            }
            guard let result else { return }
            // Give the window server a moment to remove the overlay before capturing.
            try? await Task.sleep(for: .milliseconds(selfTimer ? 120 : 40))

            switch result.target {
            case .area(let rect) where selfTimer:
                // macOS's screencapture counts down (-T) under the red pill, as All-In-One's Timer does.
                Defaults[Prefs.lastAreaRect] = rect.storageString
                guard let image = await NativeScreencapture.capture(rect: rect, timer: Defaults[Prefs.selfTimerInterval],
                                                                     showCursor: Defaults[Prefs.showCursor]) else { return }
                CaptureOutput.deliver(image, scale: result.screen.backingScaleFactor, options: options, screenRect: rect)
            case .area(let rect):
                Defaults[Prefs.lastAreaRect] = rect.storageString
                if freeze, !selfTimer, let snap = snapshots[result.screen.displayID] {
                    let scale = result.screen.backingScaleFactor
                    let local = rect.offsetBy(dx: -result.screen.cgFrame.minX, dy: -result.screen.cgFrame.minY)
                    let px = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale).integral
                    if let cropped = snap.cropping(to: px) { CaptureOutput.deliver(cropped, scale: scale, options: options, screenRect: rect) }
                } else {
                    await captureRect(rect, on: result.screen, showCursor: selfTimer && Defaults[Prefs.showCursor], options: options)
                }
            case .window(let id, let frame):
                if selfTimer { await Countdown.run(seconds: Defaults[Prefs.selfTimerInterval], on: result.screen) }
                await captureWindow(id: id, frame: frame, screen: result.screen, options: options)
            }
        }
    }

    /// All-In-One: captures an area that's already selected, after the Timer's countdown when `timer` is set.
    func captureSelected(_ rect: CGRect, on screen: NSScreen, timer: Bool = false) {
        guard !isBusy else { return }
        isBusy = true
        Defaults[Prefs.lastAreaRect] = rect.storageString
        Task {
            defer { isBusy = false }
            guard timer else {
                // Give the window server a moment to remove the overlay before capturing.
                try? await Task.sleep(for: .milliseconds(40))
                await captureRect(rect, on: screen, showCursor: false, options: nil)
                return
            }
            // Like the Timer shortcut: macOS's screencapture counts down (-T) under the red pill.
            guard let image = await NativeScreencapture.capture(rect: rect, timer: Defaults[Prefs.selfTimerInterval],
                                                                 showCursor: Defaults[Prefs.showCursor]) else { return }
            CaptureOutput.deliver(image, scale: screen.backingScaleFactor, options: nil, screenRect: rect)
        }
    }

    func capturePreviousArea() {
        guard let rect = CGRect(storageString: Defaults[Prefs.lastAreaRect]), let screen = NSScreen.containing(cgRect: rect) else {
            captureArea()
            return
        }
        guard !isBusy, Permissions.ensureScreenRecording() else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            await captureRect(rect.intersection(screen.cgFrame), on: screen, showCursor: false, options: nil)
        }
    }

    func captureFullscreen() {
        guard !isBusy, Permissions.ensureScreenRecording(), let screen = NSScreen.withMouse else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            let hideIcons = Defaults[Prefs.hideDesktopIconsWhileCapturing] && !DesktopIconsHider.shared.isHidingIcons
            if hideIcons {
                await DesktopIconsHider.shared.hideAndWait()
                try? await Task.sleep(for: .milliseconds(60))
            }
            await captureRect(screen.cgFrame, on: screen, showCursor: Defaults[Prefs.showCursor], options: nil)
            if hideIcons { DesktopIconsHider.shared.show(animated: false) }
        }
    }

    private func captureRect(_ rect: CGRect, on screen: NSScreen, showCursor: Bool, options: AfterCaptureOptions?) async {
        do {
            let image = try await ScreenCapturer.capture(rect: rect, on: screen, showCursor: showCursor)
            CaptureOutput.deliver(image, scale: screen.backingScaleFactor, options: options, screenRect: rect)
        } catch {
            NSLog("Glint: capture failed: \(error)")
            NSSound.beep()
        }
    }

    private func captureWindow(id: CGWindowID, frame: CGRect, screen: NSScreen, options: AfterCaptureOptions?) async {
        // A full-screen window has no shadow or rounded corners, so it's treated like a normal screenshot in the editor;
        // other windows keep their raw (transparent, shadowed) image so the editor can re-pad them on the wallpaper.
        let isFullScreenWindow = abs(frame.width - screen.frame.width) < 2 && abs(frame.height - screen.frame.height) < 2
        do {
            let transparent = Defaults[Prefs.windowBackground] == .transparent || NSEvent.modifierFlags.contains(.shift)
            let window = try await ScreenCapturer.capture(windowID: id, includeShadow: Defaults[Prefs.windowShadow])
            let scale = screen.backingScaleFactor
            if transparent {
                CaptureOutput.deliver(window, scale: scale, options: options, windowImage: isFullScreenWindow ? nil : window,
                                      windowOnWallpaper: false)
            } else {
                let wallpaper = await WallpaperProvider.image(for: screen)
                let pad = WindowComposer.padding(around: window, frame: frame.size, scale: scale)
                let composed = WindowComposer.compose(window: window, wallpaper: wallpaper, scale: scale, padding: pad)
                CaptureOutput.deliver(composed ?? window, scale: scale, options: options,
                                      windowImage: isFullScreenWindow ? nil : window, windowOnWallpaper: true, windowPadding: pad)
            }
        } catch {
            NSLog("Glint: window capture failed: \(error)")
            NSSound.beep()
        }
    }
}

/// Places a window screenshot on the wallpaper with padding.
enum WindowComposer {
    /// Wallpaper on each side of the window frame (its shadow lies within) for the 7 slider steps, in points.
    /// 78pt at the first step, +20pt per step (default, step 3: 118pt).
    static let paddingSteps: [CGFloat] = [78, 98, 118, 138, 158, 178, 198]

    /// The setting's padding from the window frame, in points.
    static var framePadding: CGFloat {
        paddingSteps[min(max(Int(Defaults[Prefs.windowPadding].rounded()), 0), paddingSteps.count - 1)]
    }

    /// Wallpaper to add around the captured window image (which already includes the shadow) so the frame gets
    /// `framePadding`, in points.
    static func padding(around window: CGImage, frame: CGSize, scale: CGFloat) -> CGFloat {
        let shadow = max(0, (CGFloat(window.width) / scale - frame.width) / 2)
        return max(0, framePadding - shadow)
    }

    static func compose(window: CGImage, wallpaper: CGImage?, scale: CGFloat, padding: CGFloat) -> CGImage? {
        let pad = padding * scale
        let w = CGFloat(window.width) + pad * 2, h = CGFloat(window.height) + pad * 2
        guard let ctx = ImageProcessing.context(width: Int(w), height: Int(h), colorSpace: window.colorSpace) else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: w, height: h)
        if let wallpaper { WallpaperProvider.drawAspectFill(wallpaper, in: canvas, ctx: ctx) }
        ctx.draw(window, in: CGRect(x: pad, y: pad, width: CGFloat(window.width), height: CGFloat(window.height)))
        return ctx.makeImage()
    }
}

/// Big countdown numbers in the middle of the screen for Self-Timer.
enum Countdown {
    static func run(seconds: Int, on screen: NSScreen) async {
        let size = CGSize(width: 160, height: 160)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 32
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 84, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = CGRect(x: 0, y: 28, width: size.width, height: 100)
        effect.addSubview(label)
        panel.contentView = effect
        panel.orderFrontRegardless()
        for n in stride(from: seconds, to: 0, by: -1) {
            label.stringValue = "\(n)"
            if Defaults[Prefs.playSounds] { NSSound(named: "Tink")?.play() }
            try? await Task.sleep(for: .seconds(1))
        }
        panel.orderOut(nil)
    }
}

/// Placeholder for features scheduled in later milestones.
enum ComingSoon {
    static func show(_ feature: String) {
        // Overlays (recording area, All-In-One) sit above the modal-panel level; lower them while the alert is up
        // so it can be clicked, then put them and their key focus back.
        let key = NSApp.keyWindow
        let raised = NSApp.windows.filter { $0.isVisible && $0.level > .modalPanel }
        let levels = raised.map(\.level)
        raised.forEach { $0.level = .floating }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(feature) isn't built yet"
        alert.informativeText = "This feature is planned for a later version of Glint."
        alert.runModal()
        zip(raised, levels).forEach { $0.level = $1 }
        key?.makeKeyAndOrderFront(nil)
    }
}
