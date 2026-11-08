import AppKit
import CoreImage
import CoreText

// MARK: - Model

/// One spoken word, in source seconds.
struct CaptionWord: Hashable, Codable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A caption: a phrase or sentence with its words, in source seconds (cuts and trims hide what they remove, like the
/// Studio Mode events).
struct Caption: Hashable, Identifiable, Codable, Sendable {
    var id = UUID()
    var words: [CaptionWord]
    /// Where the speech put it (source seconds), so a moved caption can go back; nil for ones added by hand.
    var matched: [Double]?

    init(words: [CaptionWord], matched: Bool = false) {
        self.words = words
        if matched, let first = words.first, let last = words.last { self.matched = [first.start, last.end] }
    }

    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }

    /// New text typed for the caption: words that stayed keep their times, the rest share the caption's time evenly.
    mutating func setText(_ text: String) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { words = []; return }
        let old = words.map(\.text)
        if tokens.count == old.count {
            for i in tokens.indices { words[i].text = tokens[i] }
            return
        }
        words = Self.spread(tokens, from: start, to: max(end, start + 0.3))
    }

    /// Moves the caption (and its words) to start at `newStart`, or stretches it to `newStart…newEnd`.
    mutating func retime(start newStart: Double, end newEnd: Double) {
        let s = start, length = max(end - s, 0.001), newLength = max(newEnd - newStart, 0.1)
        words = words.map { w in
            CaptionWord(text: w.text, start: newStart + (w.start - s) / length * newLength, end: newStart + (w.end - s) / length * newLength)
        }
    }

    static func spread(_ tokens: [String], from start: Double, to end: Double) -> [CaptionWord] {
        let step = (end - start) / Double(max(tokens.count, 1))
        return tokens.enumerated().map { i, t in CaptionWord(text: t, start: start + Double(i) * step, end: start + Double(i + 1) * step) }
    }
}

enum CaptionMode: String, Codable, CaseIterable, Sendable {
    /// Whole phrases, up to two lines (more formal).
    case phrases
    /// A few words at a time, each appearing as it's spoken (social media).
    case words
    var title: String { self == .phrases ? "Phrases" : "Word by Word" }
}

enum CaptionAnimation: String, Codable, CaseIterable, Sendable {
    case none, pop, fade
    var title: String { rawValue.capitalized }
}

enum CaptionFont: String, Codable, CaseIterable, Sendable {
    case system, rounded, mono, handwritten
    var title: String { ["System", "Rounded", "Mono", "Handwritten"][Self.allCases.firstIndex(of: self) ?? 0] }

    nonisolated func font(size: CGFloat, bold: Bool) -> NSFont {
        let weight: NSFont.Weight = bold ? .heavy : .semibold
        switch self {
        case .system: return NSFont.systemFont(ofSize: size, weight: weight)
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case .handwritten:
            return NSFont(name: "MarkerFelt-Wide", size: size) ?? NSFont(name: "Noteworthy-Bold", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        }
    }
}

enum CaptionPosition: String, Codable, CaseIterable, Sendable {
    case top, middle, bottom
    var title: String { rawValue.capitalized }
}

enum CaptionPreset: String, Codable, CaseIterable, Sendable {
    case classic, outline, social, minimal
    var title: String { self == .social ? "Social Media" : rawValue.capitalized }
    var help: String {
        switch self {
        case .classic: "White text on a dark box at the bottom, whole phrases"
        case .outline: "White text with a black outline, no box"
        case .social: "Big bold words that appear as they're spoken, in the lower third"
        case .minimal: "Small text on a light, see-through box"
        }
    }
}

/// How captions look and behave. The presets fill in all of it; every value can be changed afterwards.
struct CaptionStyle: Hashable, Codable, Sendable {
    var preset: CaptionPreset = .classic
    var mode: CaptionMode = .phrases
    var font: CaptionFont = .system
    /// 1 = the default size (about 4.5% of the video's shorter side).
    var size: Double = 1
    var bold = false
    var uppercase = false
    /// Display P3 hex, like the annotation colors.
    var textColor: UInt32 = 0xFFFFFF
    var highlightColor: UInt32 = 0xFAE24C
    /// Phrases: the word being spoken; Word by Word: the newest word.
    var highlightWord = false
    var box = true
    var boxColor: UInt32 = 0x000000
    var boxOpacity: Double = 0.72
    var outline = false
    var position: CaptionPosition = .bottom
    /// Fine placement: -0.5…0.5 of the video's height (positive moves up).
    var offset: Double = 0
    /// Phrases: the longest line, in characters.
    var lineLength = 42
    /// Word by Word: the most words on screen at once.
    var wordsPerChunk = 3
    var animation: CaptionAnimation = .none

    static func preset(_ p: CaptionPreset) -> CaptionStyle {
        var s = CaptionStyle()
        s.preset = p
        switch p {
        case .classic:
            break
        case .outline:
            s.box = false
            s.outline = true
            s.bold = true
        case .social:
            s.mode = .words
            s.size = 1.7
            s.bold = true
            s.uppercase = true
            s.box = false
            s.outline = true
            s.position = .middle
            s.offset = -0.18
            s.animation = .pop
            s.wordsPerChunk = 3
        case .minimal:
            s.size = 0.8
            s.textColor = 0x1C1C1E
            s.boxColor = 0xFFFFFF
            s.boxOpacity = 0.78
        }
        return s
    }

    /// The default for new captions (Settings → Screen Recording → Captions).
    static var standard: CaptionStyle {
        preset(CaptionPreset(rawValue: UserDefaults.standard.string(forKey: "captions.preset") ?? "") ?? .classic)
    }
}

// MARK: - Layout

/// What's on screen at a moment: lines of words with the time each word appears and whether it's highlighted.
nonisolated struct CaptionFrame {
    struct Word { var text: String; var appear: Double; var highlighted: Bool }
    var lines: [[Word]]
    /// When the whole caption appeared (for the phrase fade).
    var appear: Double
}

/// Captions on the output timeline (cut parts removed), and how to show them at a time.
nonisolated struct CaptionTimeline: Sendable {
    /// Words in output seconds, per caption.
    let captions: [[CaptionWord]]
    let style: CaptionStyle

    /// Pauses longer than this, and punctuation, end a Word by Word chunk.
    static let pause = 0.3
    /// Words appear this much before they're spoken.
    static let lead = 0.05

    func frame(at t: Double) -> CaptionFrame? {
        style.mode == .phrases ? phrase(at: t) : chunk(at: t)
    }

    private func current(at t: Double) -> [CaptionWord]? {
        captions.first { words in
            guard let first = words.first, let last = words.last else { return false }
            return t >= first.start - Self.lead && t < last.end + 0.25
        }
    }

    private func phrase(at t: Double) -> CaptionFrame? {
        guard let words = current(at: t) else { return nil }
        // Long captions: pages of up to two lines, each shown while its words are spoken.
        let pages = Self.pages(words.map(\.text), lineLength: style.lineLength)
        var page = pages.first ?? []
        for p in pages {
            guard let first = p.first else { continue }
            if words[first].start - Self.lead <= t { page = p } else { break }
        }
        let spoken = words.lastIndex { $0.start <= t }
        var lines: [[CaptionFrame.Word]] = [[]]
        var length = 0
        for i in page {
            let word = words[i]
            if length > 0, length + word.text.count + 1 > style.lineLength, lines.count < 2 { lines.append([]); length = 0 }
            // Highlight: every word spoken so far.
            lines[lines.count - 1].append(.init(text: word.text, appear: words[page.first ?? i].start - Self.lead,
                                                highlighted: style.highlightWord && spoken.map { i <= $0 } ?? false))
            length += word.text.count + (length > 0 ? 1 : 0)
        }
        return CaptionFrame(lines: lines, appear: words[page.first ?? 0].start - Self.lead)
    }

    /// Indexes of the words on each page (up to two lines of `lineLength` characters).
    static func pages(_ words: [String], lineLength: Int) -> [[Int]] {
        var pages: [[Int]] = [], page: [Int] = [], lines = 1, length = 0
        for (i, w) in words.enumerated() {
            if length > 0, length + w.count + 1 > lineLength {
                if lines == 2 { pages.append(page); page = []; lines = 1 } else { lines += 1 }
                length = 0
            }
            page.append(i)
            length += w.count + (length > 0 ? 1 : 0)
        }
        if !page.isEmpty { pages.append(page) }
        return pages
    }

    /// Word by Word: the chunk around `t`; its words appear one by one.
    private func chunk(at t: Double) -> CaptionFrame? {
        guard let words = current(at: t) else { return nil }
        let chunks = Self.chunks(words, size: style.wordsPerChunk)
        guard let chunk = chunks.last(where: { words[$0.first ?? 0].start - Self.lead <= t }) else { return nil }
        // The chunk stays until the next one starts (or a moment after its last word).
        guard let lastWord = chunk.last.map({ words[$0] }), t < lastWord.end + 0.6 else { return nil }
        let newest = chunk.last { words[$0].start - Self.lead <= t }
        var lines: [[CaptionFrame.Word]] = [[]]
        var length = 0
        let maxLine = max(style.lineLength / 2, 12)
        // Only the words already said: the box grows with them.
        for i in chunk where words[i].start - Self.lead <= t {
            let w = words[i]
            if length > 0, length + w.text.count + 1 > maxLine, lines.count < 2 { lines.append([]); length = 0 }
            lines[lines.count - 1].append(.init(text: w.text, appear: w.start - Self.lead, highlighted: style.highlightWord && i == newest))
            length += w.text.count + (length > 0 ? 1 : 0)
        }
        return CaptionFrame(lines: lines, appear: words[chunk.first ?? 0].start - Self.lead)
    }

    /// Groups of up to `size` words, broken after punctuation and before pauses.
    static func chunks(_ words: [CaptionWord], size: Int) -> [[Int]] {
        var chunks: [[Int]] = [], current: [Int] = []
        for (i, w) in words.enumerated() {
            if let last = current.last, current.count >= size || w.start - words[last].end > pause {
                chunks.append(current)
                current = []
            }
            current.append(i)
            if let c = w.text.last, ".,!?;:…".contains(c) { chunks.append(current); current = [] }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

// MARK: - Rendering

/// Draws the captions onto the video (y-up pixels), placed by the style; `lift` keeps them above Studio Mode's
/// keystroke labels when both sit at the bottom.
nonisolated final class CaptionRenderer: @unchecked Sendable {
    let timeline: CaptionTimeline
    /// Keystroke labels at the bottom: their size factor (nil = none there).
    let keysAtBottom: Double?

    init(timeline: CaptionTimeline, keysAtBottom: Double?) {
        self.timeline = timeline
        self.keysAtBottom = keysAtBottom
    }

    func draw(on video: CIImage, size: CGSize, time: Double) -> CIImage {
        guard let frame = timeline.frame(at: time), let image = Self.image(frame, style: timeline.style, width: size.width,
                                                                          short: min(size.width, size.height), time: time)
        else { return video }
        let style = timeline.style
        let short = min(size.width, size.height)
        let margin = short * 0.06
        var y: CGFloat = switch style.position {
        case .top: size.height - margin - image.extent.height
        case .middle: (size.height - image.extent.height) / 2
        case .bottom: margin
        }
        if style.position == .bottom, let k = keysAtBottom {
            // Above the keystroke pill (its height and margin, as `StudioOverlay` draws it).
            y += short * 0.045 + max(12, (short * 0.042 * k).rounded()) * 2 - margin + short * 0.02
        }
        y += CGFloat(style.offset) * size.height
        y = min(max(y, 0), size.height - image.extent.height)
        let x = (size.width - image.extent.width) / 2
        return image.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: video)
    }

    /// The caption block: a rounded box (if any) with the words, each in its own state (appearing, highlighted).
    static func image(_ frame: CaptionFrame, style: CaptionStyle, width maxWidth: CGFloat, short: CGFloat, time: Double) -> CIImage? {
        let fontSize = max(10, short * 0.045 * CGFloat(style.size))
        let font = style.font.font(size: fontSize, bold: style.bold)
        let textColor = color(style.textColor), highlight = color(style.highlightColor)
        func string(_ text: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: style.uppercase ? text.uppercased() : text, attributes: [.font: font, .foregroundColor: color])
        }
        let space = string(" ", textColor).size().width
        let lineHeight = (font.ascender - font.descender + font.leading) * 1.08
        // Measure every word (all of them, so appearing words don't move the others).
        let measured = frame.lines.map { line in line.map { (word: $0, width: string($0.text, textColor).size().width) } }
        let lineWidths = measured.map { line in line.reduce(0) { $0 + $1.width } + space * CGFloat(max(line.count - 1, 0)) }
        let padX = fontSize * 0.55, padY = fontSize * 0.28
        let outlineWidth = style.outline ? max(2, fontSize * 0.12) : 0
        let width = min((lineWidths.max() ?? 0) + padX * 2 + outlineWidth * 2, maxWidth)
        let height = lineHeight * CGFloat(measured.count) + padY * 2 + outlineWidth * 2
        guard width > 1, height > 1,
              let ctx = CGContext(data: nil, width: Int(width.rounded(.up)), height: Int(height.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Phrases fade in and out quickly; Word by Word animates each word.
        let phraseAlpha = style.mode == .phrases ? min(max((time - frame.appear) / 0.12, 0), 1) : 1
        if style.box {
            ctx.setFillColor(color(style.boxColor).withAlphaComponent(style.boxOpacity * phraseAlpha).cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height), cornerWidth: fontSize * 0.45,
                               cornerHeight: fontSize * 0.45, transform: nil))
            ctx.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (row, line) in measured.enumerated() {
            var x = (width - lineWidths[row]) / 2
            let baseline = height - padY - outlineWidth - lineHeight * CGFloat(row + 1) - font.descender
            for (word, w) in line {
                defer { x += w + space }
                let age = time - word.appear
                guard age >= 0 || style.mode == .phrases else { continue }
                var alpha = phraseAlpha, scale: CGFloat = 1
                if style.mode == .words {
                    let p = min(max(age / 0.14, 0), 1)
                    switch style.animation {
                    case .none: break
                    case .fade: alpha = p
                    case .pop:
                        // A quick grow with a slight overshoot.
                        scale = p < 1 ? 0.6 + 0.48 * sin(p * .pi * 0.62) / sin(.pi * 0.62) : 1
                        alpha = min(p * 2, 1)
                    }
                }
                let fill = (word.highlighted ? highlight : textColor).withAlphaComponent(alpha)
                let text = style.uppercase ? word.text.uppercased() : word.text
                ctx.saveGState()
                let center = CGPoint(x: x + w / 2, y: baseline + font.capHeight / 2)
                ctx.translateBy(x: center.x, y: center.y)
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -center.x, y: -center.y)
                if style.outline {
                    // The letters drawn in black around a circle (a stroked outline spikes at sharp corners, like a Y's).
                    let shadow = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
                    for k in 0..<12 {
                        let a = Double(k) / 12 * .pi * 2
                        shadow.draw(at: CGPoint(x: x + cos(a) * outlineWidth, y: baseline + font.descender + sin(a) * outlineWidth))
                    }
                }
                NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fill]).draw(at: CGPoint(x: x, y: baseline + font.descender))
                ctx.restoreGState()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    static func color(_ hex: UInt32) -> NSColor { AnnotationColor(hex: hex).nsColor }
}

// MARK: - Subtitles file

enum SubtitleFile {
    /// SubRip (.srt): one entry per caption, in output time (cut parts left out).
    static func srt(_ captions: [[CaptionWord]]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((max(t, 0) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        var out = "", n = 0
        for words in captions where !words.isEmpty {
            n += 1
            let text = wrap(words.map(\.text), lineLength: 42)
            out += "\(n)\n\(stamp(words[0].start)) --> \(stamp(words[words.count - 1].end))\n\(text)\n\n"
        }
        return out
    }

    private static func wrap(_ words: [String], lineLength: Int) -> String {
        var lines: [String] = [""]
        for w in words {
            if !lines[lines.count - 1].isEmpty, lines[lines.count - 1].count + w.count + 1 > lineLength { lines.append("") }
            lines[lines.count - 1] += (lines[lines.count - 1].isEmpty ? "" : " ") + w
        }
        return lines.joined(separator: "\n")
    }
}
