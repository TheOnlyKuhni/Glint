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
///     glint://debug-drag?x1=…&y1=…&x2=…&y2=…[&mods=…]
///     glint://debug-move?x=…&y=…   (the pointer moves there: hover effects)
///     glint://debug-resize?w=…&h=…   (the window's size; "min" for its minimum)
///     glint://debug-screenshot?path=/tmp/x.png   (the main display, Glint's windows included)
///     glint://debug-film?dir=/tmp/f&x=&y=&w=&h=&seconds=2&fps=30   (frames of a rect, for animations)
///     glint://debug-ocr?path=/tmp/qr.png   (Capture Text on an image file: copy + toast)
///     glint://debug-action?sel=undo:   (a menu action through the window's responder chain, e.g. undo:, redo:)
///
/// Each accepts `win=<window number>`; the default is Glint's frontmost regular window.
enum DebugHooks {
    static func handle(_ command: String, _ query: [String: String]) -> Bool {
        guard command.hasPrefix("debug-") else { return false }
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
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    window.sendEvent(e)
                }
            }
        case "debug-click":
            if let delay = query["closeMenu"].flatMap(Double.init) { closeNextMenu(after: delay) }
            if let title = query["pick"] { closeNextMenu(after: 0.3, picking: title) }
            let p = point("x", "y")
            let count = Int(query["count"] ?? "") ?? 1
            for n in 1...count {
                mouse(.leftMouseDown, p, mods, n, window, queued: query["queue"] == "1")
                mouse(.leftMouseUp, p, mods, n, window, queued: query["queue"] == "1")
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
            mouse(.leftMouseUp, b, mods, 1, window)
        default:
            glintLog("debug: unknown \(command)")
        }
        return true
    }

    /// Menus run their own tracking loop, so the close is scheduled in the common run loop modes.
    private static func closeNextMenu(after delay: Double, picking title: String? = nil) {
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let menu = note.object as? NSMenu else { return }
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                menu.cancelTracking()
                if let title, let i = menu.items.firstIndex(where: { $0.title == title || $0.toolTip == title }) {
                    DispatchQueue.main.async { menu.performActionForItem(at: i) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private static func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ mods: NSEvent.ModifierFlags, _ clicks: Int, _ window: NSWindow,
                              queued: Bool = false) {
        guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                         pressure: type == .leftMouseUp ? 0 : 1) else { return }
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
