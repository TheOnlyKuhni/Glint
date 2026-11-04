import AppKit
import AVFoundation
import CoreImage

// MARK: - Settings (part of `VideoEdit`, so undoable and saved with the edit)

enum CursorStyle: String, Codable, CaseIterable {
    /// The cursors exactly as they looked while recording.
    case system, bold, light, touch
    var title: String {
        switch self {
        case .system: "macOS"
        case .bold: "Bold"
        case .light: "Light"
        case .touch: "Touch"
        }
    }
}

enum CursorMovement: String, Codable { case natural, smooth }

enum RippleColor: String, Codable, CaseIterable {
    case blue, purple, pink, orange, yellow, green, gray
    var title: String { rawValue.capitalized }
    nonisolated var color: NSColor {
        switch self {
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .gray: .systemGray
        }
    }
}

/// Where keystrokes or the camera sit in the video.
enum OverlayCorner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottom, bottomRight
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }
    nonisolated var isTop: Bool { self == .topLeft || self == .topRight }
}

struct CursorSettings: Equatable, Codable {
    var show = true
    /// 0.5…3 (100% = as recorded).
    var size: Double = 1.5
    var style: CursorStyle = .system
    var movement: CursorMovement = .smooth
    /// The cursor shrinks a little while a button is held.
    var pressEffect = true
    var ripple = false
    var rippleColor: RippleColor = .blue
    var rippleFilled = false
    var hideWhenIdle = false
    var hideWhenTyping = false
}

/// Which keys keystroke labels show.
enum KeystrokeFilter: String, Codable, CaseIterable {
    /// Everything: typed text, special keys (↩, esc, arrows…) and shortcuts.
    case all
    /// Only typed text (letters, digits, punctuation, spaces).
    case text
    /// Only keys pressed with ⌘, ⌥ or ⌃.
    case shortcuts

    var title: String {
        switch self {
        case .all: "All Keys"
        case .text: "Text"
        case .shortcuts: "Shortcuts"
        }
    }

    var help: String {
        switch self {
        case .all: "Everything you press: typed text, keys like ↩ or esc, and shortcuts"
        case .text: "Only what you type: letters, digits, punctuation and spaces"
        case .shortcuts: "Only shortcuts: keys pressed with ⌘, ⌥ or ⌃"
        }
    }

    /// Glint's setting (Settings → Recording → Keystrokes), also what a new Studio project starts with. Before the
    /// presets there was "Only shortcuts".
    static var setting: KeystrokeFilter {
        get {
            if let raw = UserDefaults.standard.string(forKey: Prefs.recKeysFilter.key), let filter = KeystrokeFilter(rawValue: raw) { return filter }
            return Defaults[Prefs.recKeysShortcutsOnly] ? .shortcuts : .all
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Prefs.recKeysFilter.key) }
    }
}

/// A key, with the modifiers held, that keystroke labels never show (e.g. ⌘ Tab, or a password manager's shortcut).
nonisolated struct ExcludedKey: Codable, Hashable, Sendable {
    var code: Int
    /// ⌃ ⌥ ⇧ ⌘ only.
    var flags: UInt
    /// The key's character, for its label.
    var chars: String

    init(code: Int, flags: UInt, chars: String) {
        self.code = code
        self.flags = NSEvent.ModifierFlags(rawValue: flags).intersection(Self.modifiers).rawValue
        self.chars = chars
    }

    private static let modifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    func matches(code: Int, flags: UInt) -> Bool {
        code == self.code && NSEvent.ModifierFlags(rawValue: flags).intersection(Self.modifiers).rawValue == self.flags
    }

    /// "⌘ C", "esc", "⇧ A".
    var label: String {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var parts: [String] = []
        if f.contains(.control) { parts.append("⌃") }
        if f.contains(.option) { parts.append("⌥") }
        if f.contains(.shift) { parts.append("⇧") }
        if f.contains(.command) { parts.append("⌘") }
        parts.append(KeyLabel.special(code) ?? (chars.isEmpty ? "#\(code)" : chars.uppercased()))
        return parts.joined(separator: " ")
    }

    /// Glint's setting (Settings → Recording → Keystrokes): what a new Studio project starts with.
    static var setting: [ExcludedKey] {
        get { (try? JSONDecoder().decode([ExcludedKey].self, from: Data(Defaults[Prefs.recKeysExcluded].utf8))) ?? [] }
        set { Defaults[Prefs.recKeysExcluded] = (try? String(decoding: JSONEncoder().encode(newValue), as: UTF8.self)) ?? "" }
    }
}

struct KeystrokeSettings: Equatable, Codable {
    var show = false
    /// 0.5…2.
    var size: Double = 1
    var light = false
    var position: OverlayCorner = .bottom
    var filter: KeystrokeFilter = .all
    /// Keys never shown in this video.
    var excluded: [ExcludedKey] = []
}

struct CameraSettings: Equatable, Codable {
    var show = true
    /// 0.5…2 (relative to the recorder's Medium).
    var size: Double = 1
    /// Circle, square, rectangle, vertical (the recorder's shapes).
    var shape = 0
    var position: OverlayCorner = .bottomRight
    var flip = true
    var shrinkOnZoom = true
}

extension KeyedDecodingContainer {
    /// The value, or `fallback` when it's missing (edits saved by older versions) or unreadable.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
}

extension CursorSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = CursorSettings()
        self.init(show: c.value(.show, or: d.show), size: c.value(.size, or: d.size), style: c.value(.style, or: d.style),
                  movement: c.value(.movement, or: d.movement), pressEffect: c.value(.pressEffect, or: d.pressEffect),
                  ripple: c.value(.ripple, or: d.ripple), rippleColor: c.value(.rippleColor, or: d.rippleColor),
                  rippleFilled: c.value(.rippleFilled, or: d.rippleFilled), hideWhenIdle: c.value(.hideWhenIdle, or: d.hideWhenIdle),
                  hideWhenTyping: c.value(.hideWhenTyping, or: d.hideWhenTyping))
    }
}

extension KeystrokeSettings {
    /// Edits saved before the presets had "allKeys" (on: all keys, off: shortcuts).
    private enum LegacyKeys: String, CodingKey { case allKeys }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = KeystrokeSettings()
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let oldFilter: KeystrokeFilter = legacy.value(.allKeys, or: true) ? .all : .shortcuts
        self.init(show: c.value(.show, or: d.show), size: c.value(.size, or: d.size), light: c.value(.light, or: d.light),
                  position: c.value(.position, or: d.position), filter: c.value(.filter, or: oldFilter),
                  excluded: c.value(.excluded, or: d.excluded))
    }
}

extension CameraSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = CameraSettings()
        self.init(show: c.value(.show, or: d.show), size: c.value(.size, or: d.size), shape: c.value(.shape, or: d.shape),
                  position: c.value(.position, or: d.position), flip: c.value(.flip, or: d.flip),
                  shrinkOnZoom: c.value(.shrinkOnZoom, or: d.shrinkOnZoom))
    }
}

// MARK: - Camera actions

/// The camera actions a Studio Mode recording opens with: one full-size stretch for each time the camera was clicked
/// to full size while recording.
enum StudioCameraLayouts {
    static func make(_ studio: StudioRecording, duration: Double, camera: CameraSettings) -> [CameraLayout] {
        var layouts: [CameraLayout] = []
        var fullSince: Double?
        func close(_ end: Double) {
            if let start = fullSince, end - start >= 0.3 {
                layouts.append(CameraLayout(start: start, end: end, size: camera.size, shape: camera.shape, position: camera.position))
            }
            fullSince = nil
        }
        for toggle in (studio.cameraToggles ?? []).sorted(by: { $0.t < $1.t }) {
            let t = min(max(toggle.t, 0), duration)
            if toggle.full { if fullSince == nil { fullSince = t } } else { close(t) }
        }
        close(duration)
        return layouts
    }
}

// MARK: - Automatic zooms

/// The zooms a Studio Mode recording opens with: one around every burst of activity (clicks inside the area, typing),
/// following the cursor. Close bursts share one zoom.
/// What starts an automatic zoom and how it looks (Settings → Recording → Studio Mode).
struct AutoZoomSettings {
    var clicks = true
    var rightClicks = false
    var drags = true
    /// At least three keys, each less than 1.2 s after the one before (shortcuts aren't typing).
    var typing = true
    var scrolling = false
    var scale = 1.8
    /// Seconds the zoom starts before the action and stays after it.
    var before = 0.6
    var after = 1.6
    var minLength = 2.0
    /// Zooms less than this far apart become one.
    var join = 1.0
    var follow = true

    static var current: AutoZoomSettings {
        AutoZoomSettings(clicks: Defaults[Prefs.studioZoomClicks], rightClicks: Defaults[Prefs.studioZoomRightClicks],
                         drags: Defaults[Prefs.studioZoomDrags], typing: Defaults[Prefs.studioZoomTyping],
                         scrolling: Defaults[Prefs.studioZoomScrolling], scale: Defaults[Prefs.studioZoomLevel],
                         before: Defaults[Prefs.studioZoomBefore], after: Defaults[Prefs.studioZoomAfter],
                         minLength: Defaults[Prefs.studioZoomMinLength], join: Defaults[Prefs.studioZoomJoin],
                         follow: Defaults[Prefs.studioZoomFollow])
    }
}

/// The zooms a Studio Mode recording opens with: one around every burst of activity inside the area (by default
/// clicks, drags and typing), following the cursor. Close bursts share one zoom.
enum StudioZooms {
    static func make(_ studio: StudioRecording, duration: Double, settings s: AutoZoomSettings = .current) -> [VideoZoom] {
        var windows: [(Double, Double)] = []
        func add(_ a: Double, _ b: Double) { windows.append((a - s.before, b + s.after)) }
        for event in StudioEvent.make(studio) {
            switch event.kind {
            case .click where s.clicks: add(event.start, event.end)
            case .drag where s.drags: add(event.start, event.end)
            case .rightClick where s.rightClicks: add(event.start, event.end)
            case .scroll where s.scrolling: add(event.start, event.end)
            default: break
            }
        }
        // Typing: keys less than 1.2 s apart, at least three of them. Shortcuts (⌘, ⌥ or ⌃ held) aren't typing.
        if s.typing {
            var run: [Double] = []
            func flush() {
                if run.count >= 3, let a = run.first, let b = run.last { add(a, b) }
                run = []
            }
            let typed = studio.keys.filter { NSEvent.ModifierFlags(rawValue: $0.flags).isDisjoint(with: [.command, .option, .control]) }
            for key in typed.sorted(by: { $0.t < $1.t }) {
                if let last = run.last, key.t - last > 1.2 { flush() }
                run.append(key.t)
            }
            flush()
        }
        var merged: [(Double, Double)] = []
        for w in windows.sorted(by: { $0.0 < $1.0 }) {
            if let last = merged.last, w.0 - last.1 < s.join { merged[merged.count - 1].1 = max(last.1, w.1) } else { merged.append(w) }
        }
        // Too close to the next one to reach the shortest length: they join too.
        var zooms: [VideoZoom] = []
        for w in merged {
            let start = max(w.0, 0)
            let end = min(max(w.1, start + s.minLength), duration)
            if var last = zooms.last, start < last.end + s.join {
                last.end = max(last.end, end)
                zooms[zooms.count - 1] = last
            } else if end - start >= 0.5 {
                zooms.append(VideoZoom(start: start, end: end, scale: s.scale, follow: s.follow))
            }
        }
        return zooms
    }
}

// MARK: - The overlay data for one render settings snapshot

/// Where a follow-cursor zoom looks over its time (output timeline, 60 samples a second).
nonisolated struct FollowPath: Sendable {
    let start: Double
    let centers: [CGPoint]
    func center(at t: Double) -> CGPoint {
        guard !centers.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let f = max((t - start) * 60, 0)
        let i = min(Int(f), centers.count - 1), j = min(i + 1, centers.count - 1)
        let k = CGFloat(min(f - Double(i), 1))
        return CGPoint(x: centers[i].x + (centers[j].x - centers[i].x) * k, y: centers[i].y + (centers[j].y - centers[i].y) * k)
    }
}

/// The cursor over source time, sampled 120× a second: smoothed position, how visible it is.
nonisolated struct CursorPath: Sendable {
    static let rate = 120.0
    var xs: [Float] = []
    var ys: [Float] = []
    var alpha: [Float] = []

    func at(_ t: Double) -> (point: CGPoint, alpha: Double)? {
        guard !xs.isEmpty else { return nil }
        let f = max(t * Self.rate, 0)
        let i = min(Int(f), xs.count - 1), j = min(i + 1, xs.count - 1)
        let k = Float(min(f - Double(i), 1))
        return (CGPoint(x: CGFloat(xs[i] + (xs[j] - xs[i]) * k), y: CGFloat(ys[i] + (ys[j] - ys[i]) * k)),
                Double(alpha[i] + (alpha[j] - alpha[i]) * k))
    }

    static func make(_ studio: StudioRecording, mouse: [StudioRecording.Mouse], duration: Double, settings: CursorSettings) -> CursorPath {
        guard !mouse.isEmpty else { return CursorPath() }
        let n = Int(duration * rate) + 2
        let dt = 1 / rate
        var path = CursorPath()
        path.xs.reserveCapacity(n)
        path.ys.reserveCapacity(n)
        path.alpha.reserveCapacity(n)
        // Natural keeps the motion as recorded (only jitter goes); Smooth glides behind it.
        let omega = settings.movement == .smooth ? 9.0 : 40.0
        var i = 0
        var x = mouse[0].x, y = mouse[0].y, vx = 0.0, vy = 0.0
        var lastRaw = (mouse[0].x, mouse[0].y)
        var lastMove = 0.0
        var typingHidden = false
        var keyIndex = 0
        let keys = studio.keys.map(\.t).sorted()
        var visible = 1.0
        var held = false
        // Presses, so the cursor can be on the spot when each one happens (the spring alone trails the pointer and
        // reached a click only after its ripple had appeared beside it).
        let presses = mouse.filter { $0.k == .down || $0.k == .rightDown }
        var pressIndex = 0
        var lastRelease = 0.0
        for step in 0..<n {
            let t = Double(step) * dt
            while i + 1 < mouse.count, mouse[i + 1].t <= t {
                i += 1
                switch mouse[i].k {
                case .down, .rightDown: held = true; lastMove = t
                case .up, .rightUp: held = false; lastMove = t; lastRelease = t
                default: break
                }
            }
            // The recorded position: straight between close samples, held across gaps.
            var raw = (mouse[i].x, mouse[i].y)
            if i + 1 < mouse.count, t > mouse[i].t {
                let a = mouse[i], b = mouse[i + 1], span = b.t - a.t
                if span > 0, span < 0.25 { let k = (t - a.t) / span; raw = (a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k) }
            }
            if abs(raw.0 - lastRaw.0) + abs(raw.1 - lastRaw.1) > 0.0005 { lastMove = t; typingHidden = false }
            lastRaw = raw
            while keyIndex < keys.count, keys[keyIndex] <= t {
                keyIndex += 1
                if settings.hideWhenTyping { typingHidden = true }
            }
            // A critically damped spring towards the recorded position. In the last 0.35 s before a press (not reaching
            // back past the previous release) it heads for the press point instead, tighter, so it arrives in time;
            // while a button is held the cursor is exactly on the pointer (clicks and drags land where they did).
            while pressIndex < presses.count, presses[pressIndex].t <= t { pressIndex += 1 }
            var target = raw
            var w = omega
            if !held, pressIndex < presses.count, presses[pressIndex].t - t < 0.35, t >= lastRelease {
                target = (presses[pressIndex].x, presses[pressIndex].y)
                w = max(omega, 25)
            }
            vx += (w * w * (target.0 - x) - 2 * w * vx) * dt
            vy += (w * w * (target.1 - y) - 2 * w * vy) * dt
            x += vx * dt
            y += vy * dt
            if step == 0 || held { x = raw.0; y = raw.1; vx = 0; vy = 0 }
            let shows = !(settings.hideWhenIdle && !held && t - lastMove > 1.5) && !typingHidden
            visible = shows ? min(1, visible + dt / 0.15) : max(0, visible - dt / 0.3)
            path.xs.append(Float(x))
            path.ys.append(Float(y))
            path.alpha.append(Float(visible))
        }
        return path
    }
}

/// A keystroke label on screen from `start` to `end` (source time).
nonisolated struct KeyLabel: Sendable {
    var start: Double
    var end: Double
    var text: String

    static func make(_ keys: [StudioRecording.Key], filter: KeystrokeFilter, excluded: [ExcludedKey] = []) -> [KeyLabel] {
        var labels: [KeyLabel] = []
        var typing: KeyLabel?
        func endTyping() { if let t = typing { labels.append(t) }; typing = nil }
        for key in keys.sorted(by: { $0.t < $1.t }) where !excluded.contains(where: { $0.matches(code: key.code, flags: key.flags) }) {
            let flags = NSEvent.ModifierFlags(rawValue: key.flags)
            let shortcut = flags.contains(.command) || flags.contains(.control) || flags.contains(.option)
            // Space is part of the text.
            let special = key.code == 49 ? nil : Self.special(key.code)
            if !shortcut, special == nil, filter != .shortcuts {
                // Plain typing becomes one growing label (its last 24 characters).
                if var t = typing, key.t - t.end < 0.2 {
                    t.text = String((t.text + key.chars).suffix(24))
                    t.end = key.t + 1.2
                    typing = t
                } else {
                    endTyping()
                    typing = KeyLabel(start: key.t, end: key.t + 1.2, text: key.chars)
                }
                continue
            }
            // Text shows nothing else; Shortcuts only keys held with ⌘, ⌥ or ⌃.
            guard filter != .text, shortcut || filter == .all else { continue }
            endTyping()
            var parts: [String] = []
            if flags.contains(.control) { parts.append("⌃") }
            if flags.contains(.option) { parts.append("⌥") }
            if flags.contains(.shift) { parts.append("⇧") }
            if flags.contains(.command) { parts.append("⌘") }
            parts.append(special ?? key.chars.uppercased())
            labels.append(KeyLabel(start: key.t, end: key.t + 1.2, text: parts.joined(separator: " ")))
        }
        endTyping()
        // A new label replaces the one before it.
        for i in labels.indices.dropLast() where labels[i].end > labels[i + 1].start { labels[i].end = labels[i + 1].start }
        return labels
    }

    static func special(_ code: Int) -> String? {
        switch code {
        case 36, 76: "↩"
        case 48: "⇥"
        case 49: "Space"
        case 51: "⌫"
        case 117: "⌦"
        case 53: "esc"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        case 115: "↖"
        case 119: "↘"
        case 116: "⇞"
        case 121: "⇟"
        default: nil
        }
    }
}

/// What happened while a Studio recording ran, for the timeline's events track (source time; points have
/// `end == start`). Only what happened inside the recorded area counts.
nonisolated struct StudioEvent: Sendable {
    enum Kind: String, Sendable { case click, rightClick, drag, scroll, typing, shortcut, key }
    var kind: Kind
    var start: Double
    var end: Double
    /// Stays the same for the recording (what `VideoEdit.removedEvents` keeps).
    var id: String { "\(kind.rawValue)@\(Int((start * 1000).rounded()))" }
    /// Typing: what was typed; shortcut or a lone key: its label ("⌘ C", "esc").
    var text: String?

    var isKeyboard: Bool { kind == .typing || kind == .shortcut || kind == .key }

    var title: String {
        switch kind {
        case .click: return "Click"
        case .rightClick: return "Right-click"
        case .drag: return String(format: "Drag (%.1f s)", end - start)
        case .scroll: return String(format: "Scrolling (%.1f s)", end - start)
        case .typing:
            // The start of what was typed, and how many keys.
            let typed = text ?? ""
            let shown = typed.count > 24 ? typed.prefix(23).trimmingCharacters(in: .whitespaces) + "…" : typed
            return "Typing “\(shown)” (\(typed.count) \(typed.count == 1 ? "key" : "keys"))"
        case .shortcut: return "Shortcut \(text ?? "")"
        case .key: return "Key \(text ?? "")"
        }
    }

    static func make(_ studio: StudioRecording) -> [StudioEvent] {
        var events: [StudioEvent] = []
        func inside(_ m: StudioRecording.Mouse) -> Bool { (0...1).contains(m.x) && (0...1).contains(m.y) }
        // Pointer: a press that moved before its release is a drag; scrolls less than 0.6 s apart are one stretch.
        var press: StudioRecording.Mouse?
        var scroll: (start: Double, end: Double)?
        func endScroll() { if let s = scroll { events.append(StudioEvent(kind: .scroll, start: s.start, end: s.end)) }; scroll = nil }
        for m in studio.mouse {
            switch m.k {
            case .down: press = inside(m) ? m : nil
            case .up:
                guard let p = press else { continue }
                press = nil
                let moved = hypot((m.x - p.x) * studio.areaWidth, (m.y - p.y) * studio.areaHeight) > 6
                events.append(moved ? StudioEvent(kind: .drag, start: p.t, end: m.t) : StudioEvent(kind: .click, start: p.t, end: p.t))
            case .rightDown where inside(m): events.append(StudioEvent(kind: .rightClick, start: m.t, end: m.t))
            case .scroll where inside(m):
                if let s = scroll, m.t - s.end < 0.6 { scroll = (s.start, m.t) } else { endScroll(); scroll = (m.t, m.t) }
            default: break
            }
        }
        endScroll()
        // Keyboard: shortcuts one by one; other keys less than 1.2 s apart are one stretch of typing. A special key
        // (esc, ↩, arrows…) on its own isn't typing: it's shown like a shortcut.
        var typing: StudioEvent?
        func endTyping() { if let t = typing { events.append(t) }; typing = nil }
        for key in studio.keys.sorted(by: { $0.t < $1.t }) {
            let flags = NSEvent.ModifierFlags(rawValue: key.flags)
            if !flags.isDisjoint(with: [.command, .option, .control]) {
                endTyping()
                let label = KeyLabel.make([key], filter: .shortcuts).first?.text ?? key.chars
                events.append(StudioEvent(kind: .shortcut, start: key.t, end: key.t, text: label))
                continue
            }
            let special = key.code == 49 ? nil : KeyLabel.special(key.code)
            let glyph = key.code == 49 ? " " : special ?? key.chars
            let continues = typing.map { key.t - $0.end < 1.2 } ?? false
            if let special, !continues {
                endTyping()
                events.append(StudioEvent(kind: .key, start: key.t, end: key.t, text: special))
                continue
            }
            if var t = typing, continues {
                t.end = key.t
                t.text = (t.text ?? "") + glyph
                typing = t
            } else {
                endTyping()
                typing = StudioEvent(kind: .typing, start: key.t, end: key.t, text: glyph)
            }
        }
        endTyping()
        return events.sorted { $0.start < $1.start }
    }
}

/// Everything the renderer needs to draw a Studio Mode recording's cursor, clicks, keystrokes and camera, plus the
/// follow-cursor zoom paths. Made on the main thread for each look change; read from rendering threads.
nonisolated final class StudioOverlay: @unchecked Sendable {
    struct Click { var t: Double; var x: Double; var y: Double; var up: Double }

    let cursor: CursorSettings
    let keystrokes: KeystrokeSettings
    let camera: CameraSettings
    let cameraLayouts: [CameraLayout]
    /// The recorded area in points.
    let area: CGSize
    let path: CursorPath
    let mouse: [StudioRecording.Mouse]
    let clicks: [Click]
    let cursors: [StudioRecording.Cursor]
    let cursorImages: [CGImage?]
    let labels: [KeyLabel]
    let clips: [VideoClip]
    private let clipStarts: [Double]
    /// The edited length.
    private let duration: Double
    let follow: [UUID: FollowPath]

    private let lock = NSLock()
    private var labelCache: [String: CIImage] = [:]
    private var maskCache: [String: CIImage] = [:]
    private static let styled: [CursorStyle: (image: CGImage, hot: CGPoint, size: CGSize)] = {
        var result: [CursorStyle: (CGImage, CGPoint, CGSize)] = [:]
        for style in [CursorStyle.bold, .light, .touch] { if let c = StyledCursor.make(style) { result[style] = c } }
        return result
    }()

    init(studio: StudioRecording, cursorImages: [CGImage?], path: CursorPath, edit: VideoEdit, follow: [UUID: FollowPath]) {
        cursor = edit.cursor
        keystrokes = edit.keystrokes
        camera = edit.camera
        cameraLayouts = edit.cameraLayouts.sorted { $0.start < $1.start }
        area = CGSize(width: max(studio.areaWidth, 1), height: max(studio.areaHeight, 1))
        self.path = path
        mouse = studio.mouse.sorted { $0.t < $1.t }
        // Actions removed on the timeline: their click effects and keystroke labels go.
        let removed = Set(edit.removedEvents)
        let gone = removed.isEmpty ? [] : StudioEvent.make(studio).filter { removed.contains($0.id) }
        let gonePresses = gone.filter { !$0.isKeyboard }.map(\.start)
        let goneKeys = gone.filter(\.isKeyboard)
        var clicks: [Click] = []
        for (i, m) in mouse.enumerated() where (m.k == .down || m.k == .rightDown) && !gonePresses.contains(where: { abs($0 - m.t) < 0.0005 }) {
            let upKind: StudioRecording.Kind = m.k == .down ? .up : .rightUp
            let up = mouse[(i + 1)...].first { $0.k == upKind }?.t ?? m.t + 0.1
            clicks.append(Click(t: m.t, x: m.x, y: m.y, up: up))
        }
        self.clicks = clicks
        cursors = studio.cursors
        self.cursorImages = cursorImages
        let keys = studio.keys.filter { key in !goneKeys.contains { key.t >= $0.start - 0.0005 && key.t <= $0.end + 0.0005 } }
        labels = KeyLabel.make(keys, filter: edit.keystrokes.filter, excluded: edit.keystrokes.excluded)
        clips = edit.clips
        var t = 0.0
        clipStarts = edit.clips.map { clip in defer { t += clip.duration }; return t }
        duration = t
        self.follow = follow
    }

    /// The source time shown at an output time.
    func sourceTime(_ t: Double) -> Double {
        for (i, clip) in clips.enumerated() where t <= clipStarts[i] + clip.duration || i == clips.count - 1 {
            return clip.start + min(max(t - clipStarts[i], 0), clip.duration)
        }
        return t
    }

    // MARK: Drawing

    /// Draws the overlays onto the zoomed video (`size` pixels, y-up), `zoom` being the visible part of the frame.
    func draw(on video: CIImage, size: CGSize, zoom: CGRect, time: Double, camera frame: CIImage?) -> CIImage {
        var output = video
        let src = sourceTime(time)
        if cursor.show { output = drawCursor(on: output, size: size, zoom: zoom, source: src) }
        if keystrokes.show { output = drawKeys(on: output, size: size, source: src) }
        if camera.show, let frame { output = drawCamera(frame, on: output, size: size, zoom: zoom, time: time) }
        return output
    }

    private func lastIndex<T>(_ items: [T], before t: Double, time: (T) -> Double) -> Int? {
        var lo = 0, hi = items.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if time(items[mid]) <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private func drawCursor(on video: CIImage, size: CGSize, zoom: CGRect, source t: Double) -> CIImage {
        guard let state = path.at(t) else { return video }
        var output = video
        let ppp = size.width / area.width
        let zoomScale = 1 / max(zoom.width, 0.01)
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - zoom.minX) / zoom.width * size.width, y: size.height - (p.y - zoom.minY) / zoom.height * size.height)
        }
        // Click ripples, under the cursor.
        if cursor.ripple {
            let first = lastIndex(clicks, before: t - 0.5) { $0.t } .map { $0 + 1 } ?? 0
            for click in clicks[min(first, clicks.count)...] where click.t <= t {
                let p = min((t - click.t) / 0.5, 1)
                guard p < 1 else { continue }
                let base = 18 * ppp * cursor.size * zoomScale
                let ease = 1 - (1 - p) * (1 - p)
                let radius = base * (0.45 + 0.95 * ease)
                let alpha = (1 - p) * (cursor.rippleFilled ? 0.35 : 0.8)
                if let ring = Ripple.image(radius: radius, width: max(1, (3 - 2 * p) * ppp * zoomScale * 0.6), color: cursor.rippleColor.color,
                                           filled: cursor.rippleFilled, alpha: alpha) {
                    let c = place(CGPoint(x: click.x, y: click.y))
                    output = ring.transformed(by: CGAffineTransform(translationX: c.x - ring.extent.width / 2, y: c.y - ring.extent.height / 2))
                        .composited(over: output)
                }
            }
        }
        guard state.alpha > 0.01 else { return output }
        // The cursor shape at that moment, or the styled one.
        let index = lastIndex(mouse, before: t) { $0.t }.map { mouse[$0].c } ?? 0
        let info = index < cursors.count ? cursors[index] : nil
        var image: CGImage?
        var hot = CGPoint.zero
        var points = CGSize(width: 17, height: 23)
        if let styled = Self.styled[cursor.style], cursor.style == .touch || info?.type ?? .arrow == .arrow {
            (image, hot, points) = styled
        } else if let info, index < cursorImages.count, let picture = cursorImages[index] {
            image = picture
            hot = CGPoint(x: info.hotX, y: info.hotY)
            points = CGSize(width: info.width, height: info.height)
        } else if let styled = Self.styled[.bold] {
            (image, hot, points) = styled
        }
        guard let image else { return output }
        // Pressing shrinks it a little.
        var press = 0.0
        if cursor.pressEffect, cursor.style != .touch, let i = lastIndex(clicks, before: t, time: { $0.t }) {
            let c = clicks[i]
            press = t < c.up ? min(1, (t - c.t) / 0.08) : max(0, 1 - (t - c.up) / 0.12)
        }
        let scale = ppp * cursor.size * zoomScale * (1 - 0.18 * press)
        let k = scale * points.width / CGFloat(image.width)
        let tip = place(state.point)
        var picture = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: k, y: k))
        picture = picture.transformed(by: CGAffineTransform(translationX: tip.x - hot.x * scale, y: tip.y - (points.height - hot.y) * scale))
        if state.alpha < 0.999 {
            picture = picture.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(state.alpha))])
        }
        return picture.composited(over: output)
    }

    private func drawKeys(on video: CIImage, size: CGSize, source t: Double) -> CIImage {
        guard let i = lastIndex(labels, before: t, time: { $0.start }) else { return video }
        let label = labels[i]
        let fade = 0.15
        guard t < label.end + fade else { return video }
        let alpha = min(1, (t - label.start) / fade, (label.end + fade - t) / fade)
        let short = min(size.width, size.height)
        let fontSize = max(12, (short * 0.042 * keystrokes.size).rounded())
        guard var pill = labelImage(label.text, fontSize: fontSize) else { return video }
        let margin = short * 0.045
        let w = pill.extent.width, h = pill.extent.height
        let x: CGFloat = switch keystrokes.position {
        case .topLeft, .bottomLeft: margin
        case .topRight, .bottomRight: size.width - margin - w
        case .bottom: (size.width - w) / 2
        }
        let y = keystrokes.position.isTop ? size.height - margin - h : margin
        pill = pill.transformed(by: CGAffineTransform(translationX: x, y: y))
        if alpha < 0.999 { pill = pill.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))]) }
        return pill.composited(over: video)
    }

    /// The keystroke pill: dark (75% black, white text) or light (white, dark text), rounded.
    private func labelImage(_ text: String, fontSize: CGFloat) -> CIImage? {
        let key = "\(text)|\(fontSize)|\(keystrokes.light)"
        lock.lock()
        if let cached = labelCache[key] { lock.unlock(); return cached }
        lock.unlock()
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let color = keystrokes.light ? NSColor(white: 0.1, alpha: 1) : .white
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let height = (fontSize * 2).rounded(), width = (bounds.width + fontSize * 1.5).rounded()
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: fontSize * 0.55, cornerHeight: fontSize * 0.55, transform: nil))
        ctx.setFillColor(keystrokes.light ? CGColor(gray: 1, alpha: 0.94) : CGColor(gray: 0, alpha: 0.75))
        ctx.fillPath()
        let ascent = font.ascender, descent = -font.descender
        ctx.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: (height - ascent - descent) / 2 + descent)
        CTLineDraw(line, ctx)
        guard let image = ctx.makeImage() else { return nil }
        let result = CIImage(cgImage: image)
        lock.lock()
        if labelCache.count > 80 { labelCache.removeAll() }
        labelCache[key] = result
        lock.unlock()
        return result
    }

    /// Where the camera is (y-up pixels), how round, and how visible.
    private struct CameraLook {
        var rect: CGRect
        var radius: CGFloat
        var alpha: CGFloat
        func blended(to other: CameraLook, _ f: CGFloat) -> CameraLook {
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * f }
            return CameraLook(rect: CGRect(x: mix(rect.minX, other.rect.minX), y: mix(rect.minY, other.rect.minY),
                                           width: mix(rect.width, other.rect.width), height: mix(rect.height, other.rect.height)),
                              radius: mix(radius, other.radius), alpha: mix(alpha, other.alpha))
        }
    }

    /// How long the camera takes to change into or out of a layout.
    private static let cameraBlend = 0.35

    /// The bubble as big as the recorder showed it (Medium = 68 + 0.1625 × the area's shorter side), in its corner,
    /// shrinking while zoomed in when that's on.
    private func bubbleLook(size scale: Double, shape: Int, position: OverlayCorner, in size: CGSize, zoom: CGRect) -> CameraLook {
        let ppp = size.width / area.width
        let short = min(area.width, area.height)
        var side = min(68.4 + 0.1625 * short, 0.8 * short) * scale * ppp
        if camera.shrinkOnZoom {
            let zoomed = min(max((1 / max(zoom.width, 0.01) - 1) / 0.5, 0), 1)
            side *= 1 - 0.35 * zoomed
        }
        let box: CGSize = switch shape {
        case 2: CGSize(width: side * 4 / 3, height: side)
        case 3: CGSize(width: side * 3 / 4, height: side)
        default: CGSize(width: side, height: side)
        }
        let gap = (6.5 + 0.018 * short) * ppp
        let x: CGFloat = switch position {
        case .topLeft, .bottomLeft: gap
        case .bottom: (size.width - box.width) / 2
        default: size.width - gap - box.width
        }
        let y = position.isTop ? size.height - gap - box.height : gap
        let radius = shape == 0 ? min(box.width, box.height) / 2 : 22 * box.height / 166
        return CameraLook(rect: CGRect(origin: CGPoint(x: x, y: y), size: box), radius: radius, alpha: 1)
    }

    /// The camera at output time `t`: the Camera section's bubble, or the layout there, blending over `cameraBlend`
    /// from the bubble (or a layout that ends right where this one starts) and back.
    private func cameraLook(at t: Double, size: CGSize, zoom: CGRect) -> CameraLook {
        let base = bubbleLook(size: camera.size, shape: camera.shape, position: camera.position, in: size, zoom: zoom)
        func look(_ l: CameraLayout) -> CameraLook {
            switch l.kind {
            case .full: CameraLook(rect: CGRect(origin: .zero, size: size), radius: 0, alpha: 1)
            case .bubble: bubbleLook(size: l.size, shape: l.shape, position: l.position, in: size, zoom: zoom)
            case .hidden: CameraLook(rect: base.rect, radius: base.radius, alpha: 0)
            }
        }
        guard let i = cameraLayouts.firstIndex(where: { t >= $0.start && t <= $0.end }) else { return base }
        let layout = cameraLayouts[i]
        let ramp = min(Self.cameraBlend, (layout.end - layout.start) / 3)
        func ease(_ p: Double) -> CGFloat { let p = min(max(p, 0), 1); return CGFloat(p * p * (3 - 2 * p)) }
        let previous = i > 0 && cameraLayouts[i - 1].end > layout.start - 0.01 ? cameraLayouts[i - 1] : nil
        let next = i + 1 < cameraLayouts.count && cameraLayouts[i + 1].start < layout.end + 0.01 ? cameraLayouts[i + 1] : nil
        let target = look(layout)
        // Into it (not at the very start of the video, where it simply begins like this).
        if layout.start > 0.01, t < layout.start + ramp {
            return (previous.map(look) ?? base).blended(to: target, ease((t - layout.start) / ramp))
        }
        // Back out to the bubble, unless the next layout takes over right here or the video ends.
        if next == nil, layout.end < duration - 0.01, t > layout.end - ramp {
            return target.blended(to: base, ease((t - (layout.end - ramp)) / ramp))
        }
        return target
    }

    /// The camera: its picture aspect-filled into the look's rectangle, clipped round, with a soft shadow.
    private func drawCamera(_ frame: CIImage, on video: CIImage, size: CGSize, zoom: CGRect, time: Double) -> CIImage {
        let look = cameraLook(at: time, size: size, zoom: zoom)
        let bw = look.rect.width.rounded(), bh = look.rect.height.rounded()
        guard bw > 4, bh > 4, look.alpha > 0.01 else { return video }
        let radius = min(look.radius.rounded(), min(bw, bh) / 2)
        // Aspect-fill the frame into the box, mirrored if wanted.
        var picture = frame.transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
        let fw = picture.extent.width, fh = picture.extent.height
        guard fw > 0, fh > 0 else { return video }
        if camera.flip { picture = picture.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -fw, y: 0)) }
        let s = max(bw / fw, bh / fh)
        picture = picture.transformed(by: CGAffineTransform(scaleX: s, y: s))
        picture = picture.transformed(by: CGAffineTransform(translationX: -(fw * s - bw) / 2, y: -(fh * s - bh) / 2))
            .cropped(to: CGRect(x: 0, y: 0, width: bw, height: bh))
        guard let mask = mask(width: bw, height: bh, radius: radius) else { return video }
        let clear = CIImage(color: .clear).cropped(to: mask.extent)
        var bubble = picture.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: mask])
        // A soft shadow under it (none once it fills the frame).
        let blur = bw * 0.035
        let covers = bw >= size.width - 1 && bh >= size.height - 1
        if !covers {
            let shadow = mask.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
            ]).applyingGaussianBlur(sigma: blur).cropped(to: mask.extent.insetBy(dx: -blur * 3, dy: -blur * 3))
                .transformed(by: CGAffineTransform(translationX: 0, y: -bw * 0.012))
            bubble = bubble.composited(over: shadow)
        }
        if look.alpha < 0.99 {
            bubble = bubble.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: look.alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: look.alpha, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: look.alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: look.alpha),
            ])
        }
        return bubble.transformed(by: CGAffineTransform(translationX: look.rect.minX.rounded(), y: look.rect.minY.rounded())).composited(over: video)
    }

    private func mask(width: CGFloat, height: CGFloat, radius: CGFloat) -> CIImage? {
        let key = "\(width)x\(height)r\(radius)"
        lock.lock()
        if let cached = maskCache[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        guard let image = ctx.makeImage() else { return nil }
        let result = CIImage(cgImage: image)
        lock.lock()
        if maskCache.count > 40 { maskCache.removeAll() }
        maskCache[key] = result
        lock.unlock()
        return result
    }
}

/// Click ripple rings, drawn per frame (they're small).
nonisolated enum Ripple {
    static func image(radius: CGFloat, width: CGFloat, color: NSColor, filled: Bool, alpha: Double) -> CIImage? {
        let side = Int((radius + width) * 2 + 4)
        guard side > 2, side < 2000, let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let c = CGFloat(side) / 2
        let rect = CGRect(x: c - radius, y: c - radius, width: radius * 2, height: radius * 2)
        let cg = color.withAlphaComponent(CGFloat(alpha)).cgColor
        if filled {
            ctx.setFillColor(cg)
            ctx.fillEllipse(in: rect)
        } else {
            ctx.setStrokeColor(cg)
            ctx.setLineWidth(width)
            ctx.strokeEllipse(in: rect.insetBy(dx: width / 2, dy: width / 2))
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}

/// Glint's own cursor drawings: Bold (black arrow, white outline), Light (white arrow, dark outline) and Touch (a
/// soft gray dot). 2× pictures, the hot spot in points from the top left.
nonisolated enum StyledCursor {
    static func make(_ style: CursorStyle) -> (image: CGImage, hot: CGPoint, size: CGSize)? {
        let scale: CGFloat = 4
        let size = style == .touch ? CGSize(width: 28, height: 28) : CGSize(width: 20, height: 26)
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Top-left based drawing.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        if style == .touch {
            let rect = CGRect(x: 3, y: 3, width: 22, height: 22)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.3))
            ctx.setFillColor(CGColor(gray: 0.15, alpha: 0.45))
            ctx.fillEllipse(in: rect)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75))
            return ctx.makeImage().map { ($0, CGPoint(x: 14, y: 14), size) }
        }
        // The classic pointer, tip at (3, 2).
        let arrow = CGMutablePath()
        let points: [CGPoint] = [(3, 2), (3, 20.5), (7.6, 16.2), (10.6, 23.2), (13.6, 21.9), (10.7, 15.1), (16.8, 15.1)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        arrow.addLines(between: points)
        arrow.closeSubpath()
        let fill = style == .bold ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)
        let line = style == .bold ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0.12, alpha: 1)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(arrow)
        ctx.setStrokeColor(line)
        ctx.setLineWidth(3)
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(arrow)
        ctx.setFillColor(fill)
        ctx.fillPath()
        return ctx.makeImage().map { ($0, CGPoint(x: 3, y: 2), size) }
    }
}

// MARK: - Compositing (screen + camera tracks)

/// One instruction for the whole timeline: which tracks hold the screen and the camera, and the renderer.
nonisolated final class GlintCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let renderer: VideoFrameRenderer
    let screenTrack: CMPersistentTrackID
    let cameraTrack: CMPersistentTrackID?

    init(timeRange: CMTimeRange, renderer: VideoFrameRenderer, screenTrack: CMPersistentTrackID, cameraTrack: CMPersistentTrackID?) {
        self.timeRange = timeRange
        self.renderer = renderer
        self.screenTrack = screenTrack
        self.cameraTrack = cameraTrack
        requiredSourceTrackIDs = ([screenTrack] + (cameraTrack.map { [$0] } ?? [])).map { NSNumber(value: $0) }
    }
}

/// Renders each frame through `VideoFrameRenderer` with the screen and (when there is one at that moment) the
/// camera frame. Used for the preview and the export alike.
nonisolated final class GlintVideoCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA]]

    private let lastScreenLock = NSLock()
    private var lastScreen: CVPixelBuffer?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? GlintCompositionInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "Glint", code: 1))
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output))
        // A recording's sound can outlast its picture (the screen stopped changing before the end): the last frame
        // holds, as it does in a player. Without one yet (a seek straight there), black.
        lastScreenLock.lock()
        if let frame = request.sourceFrame(byTrackID: instruction.screenTrack) { lastScreen = frame }
        let screen = lastScreen
        lastScreenLock.unlock()
        let camera = instruction.cameraTrack.flatMap { request.sourceFrame(byTrackID: $0) }.map { CIImage(cvPixelBuffer: $0) }
        let picture = screen.map { CIImage(cvPixelBuffer: $0) } ?? CIImage(color: .black).cropped(to: bounds)
        let image = instruction.renderer.render(picture, camera: camera, time: request.compositionTime.seconds)
        context.render(image.composited(over: CIImage(color: .black).cropped(to: bounds)), to: output, bounds: bounds, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }
}
