#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug-only URL commands that feed synthetic events into a Glint window, so behavior can be tested while
/// Glint is in the background (no focus or pointer needed). Coordinates are window points from the top left.
///
///     glint://debug-key?chars=r&code=15[&mods=cmd,shift,opt,ctrl]
///     glint://debug-click?x=100&y=40[&count=2][&mods=…][&closeMenu=1.5]   (closes a menu it opens after 1.5 s)
///     glint://debug-click?x=…&y=…&pick=Curved   (chooses the menu item with that title or tooltip)
///     glint://debug-click?x=…&y=…&queue=1   (through the app's event queue, so event monitors see it)
///     glint://debug-click?x=…&y=…&right=1&pick=Remove   (a right-click; `pick` chooses from its menu)
///     glint://debug-drag?x1=…&y1=…&x2=…&y2=…[&mods=…]
///     glint://debug-move?x=…&y=…   (the pointer moves there: hover effects)
///     glint://debug-resize?w=…&h=…   (the window's size; "min" for its minimum)
///     glint://debug-screenshot?path=/tmp/x.png   (the main display, Glint's windows included)
///     glint://debug-film?dir=/tmp/f&x=&y=&w=&h=&seconds=2&fps=30   (frames of a rect, for animations)
///     glint://debug-ocr?path=/tmp/qr.png   (Capture Text on an image file: copy + toast)
///     glint://debug-action?sel=undo:   (a menu action through the window's responder chain, e.g. undo:, redo:)
///     glint://debug-preset   (stores one Background tool preset)
///     glint://debug-history?trash=1   (opens the Capture History, on the Trash)
///     glint://debug-state   (logs the frontmost video editor's playhead and timeline scroll)
///     glint://debug-key?…&queue=1   (through the app's event queue, so event monitors see it)
///     glint://debug-drag?…&hold=1   (no mouse-up at the end), glint://debug-mouseup?x=&y=
///     glint://debug-capture-area?x=&y=&w=&h=   (the capture flow for a rect, no selection UI)
///     glint://debug-capture-window?id=   (window capture of a CGWindowID)
///     glint://debug-record?x=&y=&w=&h=&seconds=3&mode=video|gif|studio   (a recording of a rect, no selection UI)
///
/// Each accepts `win=<window number>`; the default is Glint's frontmost regular window.
enum DebugHooks {
    static func handle(_ command: String, _ query: [String: String]) -> Bool {
        guard command.hasPrefix("debug-") else { return false }
        func rect() -> CGRect {
            CGRect(x: Double(query["x"] ?? "") ?? 100, y: Double(query["y"] ?? "") ?? 100,
                   width: Double(query["w"] ?? "") ?? 400, height: Double(query["h"] ?? "") ?? 300)
        }
        if command == "debug-history" {
            CaptureHistory.shared.show(trash: query["trash"] == "1")
            return true
        }
        if command == "debug-preset" {
            // One Background tool preset, for testing Settings → Screenshots → Background preset.
            var style = BackgroundStyle(fill: .color(0x3478F6))
            style.padding = 0.2
            BackgroundStyle.presets.append(style)
            return true
        }
        if command == "debug-capture-area", let screen = NSScreen.main {
            CaptureCoordinator.shared.captureSelected(rect(), on: screen)
            return true
        }
        if command == "debug-capture-window", let id = query["id"].flatMap(UInt32.init), let screen = NSScreen.main {
            Task {
                let content = try? await ScreenCapturer.content()
                guard let window = content?.windows.first(where: { $0.windowID == id }) else { glintLog("debug: no window \(id)"); return }
                await CaptureCoordinator.shared.captureWindow(id: id, frame: window.frame, screen: screen, options: nil)
            }
            return true
        }
        if command == "debug-record", let screen = NSScreen.main {
            let mode: RecordMode = query["mode"] == "gif" ? .gif : query["mode"] == "studio" ? .studio : .video
            let r = query["full"] == "1" ? screen.cgFrame : rect()
            RecordingController.shared.debugRecord(rect: r, screen: screen, mode: mode, seconds: Double(query["seconds"] ?? "") ?? 3)
            return true
        }
        if command == "debug-film", let dir = query["dir"] {
            // Frames of a screen rect (points, top left) for animation studies: dir/0000.png … at about `fps`.
            let seconds = Double(query["seconds"] ?? "") ?? 2, fps = Double(query["fps"] ?? "") ?? 30
            let r = CGRect(x: Double(query["x"] ?? "") ?? 0, y: Double(query["y"] ?? "") ?? 0,
                           width: Double(query["w"] ?? "") ?? 400, height: Double(query["h"] ?? "") ?? 300)
            Task {
                do {
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    let content = try await ScreenCapturer.content()
                    guard let display = content.displays.first(where: { $0.displayID == NSScreen.main?.displayID }) else { return }
                    let config = SCStreamConfiguration()
                    config.sourceRect = r
                    config.width = Int(r.width * 2)
                    config.height = Int(r.height * 2)
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let start = Date()
                    var n = 0
                    while Date().timeIntervalSince(start) < seconds {
                        let t = Date()
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        let ms = Int(t.timeIntervalSince(start) * 1000)
                        let url = URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%04d-%05dms.png", n, ms))
                        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                        n += 1
                        let wait = 1 / fps - Date().timeIntervalSince(t)
                        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                    }
                } catch { glintLog("debug-film failed: \(error)") }
            }
            return true
        }
        if command == "debug-ocr", let path = query["path"] {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return true }
            Task { await TextCapture.recognizeAndCopy(image, scale: 2, keepLineBreaks: nil) }
            return true
        }
        if command == "debug-background", let path = query["in"], let out = query["out"] {
            // Renders an image file on a white background (padding/shadow/corners/inset 0…1) at 1×, for comparing
            // the Background tool's look with reference exports.
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return true }
            var bg = BackgroundStyle(fill: .color(0xFFFFFF))
            bg.padding = CGFloat(Double(query["padding"] ?? "") ?? 0.5)
            bg.shadow = CGFloat(Double(query["shadow"] ?? "") ?? 1)
            bg.corners = CGFloat(Double(query["corners"] ?? "") ?? 0)
            bg.inset = CGFloat(Double(query["inset"] ?? "") ?? 0)
            if let result = AnnotationRenderer.export(base: image, imageSize: CGSize(width: image.width, height: image.height), effects: nil,
                                                      annotations: [], background: bg) {
                try? NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            return true
        }
        if command == "debug-screenshot", let path = query["path"] {
            // The main display with Glint's own windows (the screen as the owner sees it).
            Task {
                do {
                    let content = try await ScreenCapturer.content()
                    guard let display = content.displays.first(where: { $0.displayID == NSScreen.main?.displayID }) else { return }
                    let config = SCStreamConfiguration()
                    config.width = display.width * 2
                    config.height = display.height * 2
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                } catch { glintLog("debug-screenshot failed: \(error)") }
            }
            return true
        }
        let window = query["win"].flatMap(Int.init).flatMap { NSApp.window(withWindowNumber: $0) }
            ?? NSApp.orderedWindows.first { $0.isVisible && $0.styleMask.contains(.titled) }
        guard let window else { glintLog("debug: no window"); return true }
        let mods = modifiers(query["mods"])
        func point(_ x: String, _ y: String) -> NSPoint {
            NSPoint(x: Double(query[x] ?? "") ?? 0, y: window.frame.height - (Double(query[y] ?? "") ?? 0))
        }
        switch command {
        case "debug-state":
            glintLog((window.windowController as? VideoEditorWindowController)?.debugState ?? "no video editor")
        case "debug-mouseup":
            mouse(.leftMouseUp, point("x", "y"), mods, 1, window)
        case "debug-add-image":
            (window.windowController as? AnnotateWindowController)?.addImage(fromFile: URL(fileURLWithPath: query["path"] ?? ""))
        case "debug-action":
            let sel = NSSelectorFromString(query["sel"] ?? "")
            if !NSApp.sendAction(sel, to: nil, from: window) {
                if window.firstResponder?.tryToPerform(sel, with: nil) != true { glintLog("debug-action: nobody handles \(sel)") }
            }
        case "debug-key":
            let chars = query["chars"] ?? ""
            let code = UInt16(query["code"] ?? "") ?? 0
            // `phase=down` or `up` sends only that half (a held key).
            for type in [NSEvent.EventType.keyDown, .keyUp] where query["phase"] == nil || query["phase"] == (type == .keyDown ? "down" : "up") {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    if query["queue"] == "1" { NSApp.postEvent(e, atStart: false) } else { window.sendEvent(e) }
                }
            }
        case "debug-click":
            if let delay = query["closeMenu"].flatMap(Double.init) { closeNextMenu(after: delay) }
            if let title = query["pick"] { closeNextMenu(after: 0.3, picking: title) }
            let p = point("x", "y")
            let count = Int(query["count"] ?? "") ?? 1
            let right = query["right"] == "1"
            for n in 1...count {
                mouse(right ? .rightMouseDown : .leftMouseDown, p, mods, n, window, queued: query["queue"] == "1")
                mouse(right ? .rightMouseUp : .leftMouseUp, p, mods, n, window, queued: query["queue"] == "1")
            }
        case "debug-move":
            let p = point("x", "y")
            if let e = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0),
               let view = window.contentView?.hitTest(window.contentView!.convert(p, from: nil)) {
                view.mouseMoved(with: e)
                glintLog("debug-move: \(type(of: view))")
            } else { glintLog("debug-move: no view") }
        case "debug-resize":
            func side(_ key: String, _ min: CGFloat) -> CGFloat { query[key] == "min" ? min : CGFloat(Double(query[key] ?? "") ?? 0) }
            let size = CGSize(width: side("w", window.minSize.width), height: side("h", window.minSize.height))
            window.setFrame(CGRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        case "debug-drag":
            let a = point("x1", "y1"), b = point("x2", "y2")
            mouse(.leftMouseDown, a, mods, 1, window)
            for i in 1...12 {
                let t = CGFloat(i) / 12
                mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), mods, 1, window)
            }
            if query["hold"] != "1" { mouse(.leftMouseUp, b, mods, 1, window) }
        default:
            glintLog("debug: unknown \(command)")
        }
        return true
    }

    /// Menus run their own tracking loop, so the close is scheduled in the common run loop modes. Menus without
    /// the item (AppKit sometimes tracks an empty one first) are skipped; the watch ends after 5 s.
    private static func closeNextMenu(after delay: Double, picking title: String? = nil) {
        var token: NSObjectProtocol?
        func matches(_ item: NSMenuItem) -> Bool {
            guard let title else { return true }
            return item.title == title || item.toolTip == title || item.title.hasPrefix(title)
        }
        token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, let i = menu.items.firstIndex(where: matches),
                  !menu.items[i].title.isEmpty || title == nil else { return }
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                menu.cancelTracking()
                if title != nil { DispatchQueue.main.async { menu.performActionForItem(at: i) } }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if let token { NotificationCenter.default.removeObserver(token) } }
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ mods: NSEvent.ModifierFlags, _ clicks: Int, _ window: NSWindow,
                              queued: Bool = false) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                         pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1) else { return }
        if queued { NSApp.postEvent(e, atStart: false) } else { window.sendEvent(e) }
    }

    private static func modifiers(_ s: String?) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for m in (s ?? "").split(separator: ",") {
            switch m {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        return flags
    }
}
#endif
