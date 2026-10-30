import AppKit
import ScreenCaptureKit

/// Supplies the image used behind window screenshots and to cover desktop icons.
enum WallpaperProvider {
    static func image(for screen: NSScreen) async -> CGImage? {
        switch Defaults[Prefs.wallpaperSource] {
        case .custom:
            let path = Defaults[Prefs.wallpaperCustomPath]
            if let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return image }
        case .color:
            return solid(NSColor(hex: Defaults[Prefs.wallpaperColor]) ?? .systemBlue, size: screen.frame.size)
        case .desktop:
            // The live wallpaper window gives exactly what's on screen (dynamic wallpapers, crop, tint).
            if let live = await captureDesktopWindow(for: screen) { return live }
        }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return image
        }
        // Dynamic and system wallpapers aren't plain image files: capture the wallpaper window instead.
        return gradient(size: screen.frame.size)
    }

    /// Captures the display showing only the wallpaper layers, which gives exactly the wallpaper as macOS draws it.
    /// (Capturing the wallpaper window on its own comes back black.)
    private static func captureDesktopWindow(for screen: NSScreen) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        // Include only the wallpaper layers. (Excluding everything else doesn't work: macOS only lists
        // some apps' windows to us, and unlisted ones would stay in the picture.)
        let wallpaperTop = Int(CGWindowLevelForKey(.desktopWindow))
        let wallpaperWindows = content.windows.filter { $0.windowLayer < wallpaperTop }
        guard !wallpaperWindows.isEmpty else { return nil }
        let filter = SCContentFilter(display: display, including: wallpaperWindows)
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        config.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func solid(_ color: NSColor, size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = ImageProcessing.context(width: w, height: h, colorSpace: nil) else { return nil }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func gradient(size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = ImageProcessing.context(width: w, height: h, colorSpace: nil) else { return nil }
        let colors = [NSColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1).cgColor,
                      NSColor(red: 0.45, green: 0.25, blue: 0.85, alpha: 1).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        return ctx.makeImage()
    }

    /// Draws `image` to fill `rect` (aspect fill, centered) in `ctx`.
    static func drawAspectFill(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let s = max(rect.width / iw, rect.height / ih)
        let w = iw * s, h = ih * s
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        ctx.restoreGState()
    }
}

/// Hides desktop icons and widgets: a window just above the widget layer showing the wallpaper
/// (or the custom wallpaper/color from Settings → Wallpaper), so the background looks unchanged. Finder is untouched.
final class DesktopIconsHider {
    static let shared = DesktopIconsHider()
    private var windows: [NSWindow] = []
    private(set) var isHidingIcons = false
    private let fadeDuration: TimeInterval = 0.35
    private var spaceObserver: NSObjectProtocol?

    private init() {
        // "Update wallpaper when switching Spaces": each Space can have its own wallpaper, so the cover follows it.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopIconsHider.shared.refreshForSpaceChange() }
        }
    }

    private func refreshForSpaceChange() {
        guard isHidingIcons, Defaults[Prefs.wallpaperUpdateOnSpaceSwitch] else { return }
        Task {
            // Let the Space animation settle so the new Space's wallpaper is the one on screen.
            try? await Task.sleep(for: .milliseconds(400))
            for window in windows {
                guard let screen = NSScreen.screens.first(where: { $0.frame == window.frame }),
                      let image = await WallpaperProvider.image(for: screen), isHidingIcons else { continue }
                let fade = CATransition()
                fade.duration = 0.25
                window.contentView?.layer?.add(fade, forKey: "contents")
                window.contentView?.layer?.contents = image
            }
        }
    }

    func toggle() { isHidingIcons ? show() : hide() }

    /// Fades the icons out (menu bar / shortcut).
    func hide() { Task { await hideAndWait(animated: true) } }

    /// Covers icons and widgets; returns once the cover is fully visible (used before captures).
    func hideAndWait(animated: Bool = false) async {
        guard !isHidingIcons else { return }
        isHidingIcons = true
        var added: [NSWindow] = []
        for screen in NSScreen.screens {
            // Get the wallpaper first, so no empty (black) window is ever shown.
            guard let image = await WallpaperProvider.image(for: screen) else { continue }
            guard isHidingIcons else { added.forEach { $0.orderOut(nil) }; return }  // toggled back meanwhile
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: false)
            window.title = ScreenCapturer.includedOwnWindowTitle
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 3)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspectFill
            view.layer?.contents = image
            window.contentView = view
            window.alphaValue = animated ? 0 : 1
            window.orderFrontRegardless()
            added.append(window)
        }
        windows.append(contentsOf: added)
        guard animated else { return }
        await withCheckedContinuation { cont in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = fadeDuration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                added.forEach { $0.animator().alphaValue = 1 }
            }, completionHandler: { cont.resume() })
        }
    }

    /// Fades the icons back in.
    func show(animated: Bool = true) {
        isHidingIcons = false
        let closing = windows
        windows.removeAll()
        guard animated else { closing.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { closing.forEach { $0.orderOut(nil) } })
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
