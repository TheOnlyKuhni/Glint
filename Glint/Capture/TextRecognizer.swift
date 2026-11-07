import SwiftUI
import AppKit
import Vision

/// On-device text recognition (Vision) for Capture Text and the text-aware highlighter.
enum TextRecognizer {
    struct Line {
        let text: String
        /// In image points, top-left origin.
        let rect: CGRect
    }

    /// Uses the fast recognizer: on macOS 27 the accurate model currently never returns (tested with both Vision APIs).
    static func recognize(_ image: CGImage, scale: CGFloat) async -> [Line] {
        let languages = preferredLanguages
        return await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = true
            request.recognitionLanguages = languages
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            return (request.results ?? []).compactMap { obs -> Line? in
                guard let text = obs.topCandidates(1).first?.string else { return nil }
                let b = obs.boundingBox  // normalized, bottom-left origin
                let rect = CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height)
                return Line(text: text, rect: rect)
            }
        }.value
    }

    /// Contents of the QR codes and barcodes in the image, top to bottom.
    static func barcodes(_ image: CGImage) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let found = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            var seen = Set<String>()
            return found.compactMap(\.payloadStringValue).filter { !$0.isEmpty && seen.insert($0).inserted }
        }.value
    }

    /// Languages the (fast) recognizer can read.
    static var supportedLanguages: [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }

    /// The language chosen in Settings, or the user's system languages that the recognizer supports (English as a
    /// fallback).
    static var preferredLanguages: [String] {
        let chosen = Defaults[Prefs.ocrLanguage]
        let supported = supportedLanguages
        if chosen != "auto", supported.contains(chosen) { return [chosen] }
        let wanted = Locale.preferredLanguages.compactMap { pref in
            supported.first { $0 == pref } ?? supported.first { $0.hasPrefix(String(pref.prefix(2))) }
        }
        return Array(NSOrderedSet(array: wanted + ["en-US"])) as? [String] ?? ["en-US"]
    }

    /// Joins lines in reading order (top to bottom, then left to right).
    static func text(from lines: [Line], keepLineBreaks: Bool) -> String {
        let sorted = lines.sorted { a, b in
            abs(a.rect.midY - b.rect.midY) < min(a.rect.height, b.rect.height) / 2 ? a.rect.minX < b.rect.minX : a.rect.midY < b.rect.midY
        }
        guard keepLineBreaks, Defaults[Prefs.ocrKeepLists] else {
            return sorted.map(\.text).joined(separator: keepLineBreaks ? "\n" : " ")
        }
        return listFormatted(sorted)
    }

    /// Keeps list structure: bullets become "- ", numbering ("1.", "a)") stays, and lines that start further right
    /// than the leftmost line are indented (two spaces per step of about one line height).
    private static func listFormatted(_ lines: [Line]) -> String {
        let left = lines.map(\.rect.minX).min() ?? 0
        let height = lines.map(\.rect.height).sorted().dropFirst(lines.count / 2).first ?? 12
        let bullets: Set<Character> = ["•", "◦", "▪", "▫", "●", "○", "■", "□", "‣", "∙", "·", "–", "—", "*", "-", "➢", "►", "✓", "✔"]
        return lines.map { line in
            var text = line.text.trimmingCharacters(in: .whitespaces)
            if let first = text.first, bullets.contains(first) {
                text = "- " + text.dropFirst().trimmingCharacters(in: .whitespaces)
            }
            let steps = max(0, Int(((line.rect.minX - left) / max(height * 1.4, 1)).rounded(.down)))
            return String(repeating: "  ", count: min(steps, 6)) + text
        }.joined(separator: "\n")
    }
}

/// Capture Text (OCR): select an area, recognize its text and copy it.
enum TextCapture {
    static func run(keepLineBreaks: Bool? = nil) {
        guard Permissions.ensureScreenRecording() else { return }
        Task {
            // Glint's own selection, the same as Capture Area's.
            let overlay = SelectionOverlay(mode: .area)
            guard let result = await withCheckedContinuation({ cont in overlay.begin { cont.resume(returning: $0) } }) else {
                glintLog("ocr: no selection"); CLIReply.cancelled(); return
            }
            let rect: CGRect
            switch result.target {
            case .area(let r): rect = r
            case .window(_, let frame): rect = frame
            }
            try? await Task.sleep(for: .milliseconds(40))
            guard let image = try? await ScreenCapturer.capture(rect: rect, on: result.screen, showCursor: false) else { NSSound.beep(); return }
            await recognizeAndCopy(image, scale: result.screen.backingScaleFactor, keepLineBreaks: keepLineBreaks)
        }
    }

    /// All-In-One's OCR: the text of an area that's already selected.
    static func run(rect: CGRect, on screen: NSScreen) {
        Task {
            // Give the window server a moment to remove the overlay first.
            try? await Task.sleep(for: .milliseconds(40))
            guard let image = try? await ScreenCapturer.capture(rect: rect, on: screen, showCursor: false) else { NSSound.beep(); return }
            await recognizeAndCopy(image, scale: screen.backingScaleFactor, keepLineBreaks: nil)
        }
    }

    static func recognizeAndCopy(_ image: CGImage, scale: CGFloat, keepLineBreaks: Bool?) async {
        async let recognized = TextRecognizer.recognize(image, scale: scale)
        async let codes = TextRecognizer.barcodes(image)
        let (lines, payloads) = await (recognized, codes)
        glintLog("ocr: \(image.width)x\(image.height) → \(lines.count) lines, \(payloads.count) codes")
        let text = TextRecognizer.text(from: lines, keepLineBreaks: keepLineBreaks ?? Defaults[Prefs.ocrKeepLineBreaks])
        let code = payloads.joined(separator: "\n")
        // Its own sounds instead of the capture sound — a soft "blob" when text was copied, a
        // failure sound when there was none.
        guard !text.isEmpty || !code.isEmpty else {
            CLIReply.error("no text found")
            if Defaults[Prefs.playSounds] { NSSound(named: "Basso")?.play() }
            Toast.show(title: "No text found", detail: "Try selecting a larger area.")
            return
        }
        // A QR code's content wins (the text around a code is usually just its label), unless both are wanted.
        let copied: String, title: String
        if code.isEmpty {
            (copied, title) = (text, "Text copied to clipboard")
        } else if Defaults[Prefs.ocrCopyTextWithQR], !text.isEmpty {
            (copied, title) = (code + "\n\n" + text, "QR code and text copied")
        } else {
            (copied, title) = (code, payloads.count > 1 ? "QR codes copied to clipboard" : "QR code copied to clipboard")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copied, forType: .string)
        CLIReply.send("text \(copied)")
        if Defaults[Prefs.playSounds] { NSSound(named: "Pop")?.play() }
        // "Detect links": a link in the recognized text gets the same Open button as a QR code's.
        let textLink = code.isEmpty && Defaults[Prefs.ocrDetectLinks] ? Self.firstLink(in: text) : nil
        Toast.show(title: title, detail: code.isEmpty ? text : code, scannedCode: !code.isEmpty,
                   link: payloads.lazy.compactMap(Self.link).first ?? textLink)
    }

    private static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        guard let url = match?.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// A web link in a code's content ("https://…", or "www.…").
    private static func link(_ payload: String) -> URL? {
        let s = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("www.") { return URL(string: "https://" + s) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }
}

/// Small dark notification near the top of the screen that fades away.
enum Toast {
    private static var panel: NSPanel?

    /// `scannedCode` adds the QR badge beside the toast; `link` adds an Open button (and keeps the toast longer).
    static func show(title: String, detail: String, scannedCode: Bool = false, link: URL? = nil) {
        panel?.orderOut(nil)
        guard let screen = NSScreen.withMouse else { return }
        let view = NSHostingView(rootView: ToastView(title: title, detail: detail, scannedCode: scannedCode, link: link) {
            hide()
        })
        let size = view.fittingSize
        // 16pt below the menu bar; the view has 12pt of shadow room around the card.
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 4,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The badge and card draw their own shadows (the panel's would wrap both as one shape).
        panel.hasShadow = false
        panel.ignoresMouseEvents = link == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (link == nil ? 2.4 : 5)) { [weak panel] in
            guard let panel, panel === self.panel else { return }
            // Stays while the pointer is on it (to reach Open).
            if link != nil, panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if panel === self.panel { hide() } }
                return
            }
            hide()
        }
    }

    private static func hide() {
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }
}

private struct ToastView: View {
    let title: String
    let detail: String
    var scannedCode = false
    var link: URL?
    var dismiss: () -> Void = {}
    /// The QR badge pops in just after the card, springing up with a slight overshoot (like the recorder's toggles).
    @State private var badgeShown = false

    var body: some View {
        HStack(spacing: 8) {
            if scannedCode {
                Image(systemName: "qrcode")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    .help("QR code scanned")
                    .opacity(badgeShown ? 1 : 0)
                    .scaleEffect(badgeShown ? 1 : 0.6)
                    .offset(y: badgeShown ? 0 : 5)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
                }
                .frame(maxWidth: 340, alignment: .leading)
                if let link {
                    Button("Open") {
                        NSWorkspace.shared.open(link)
                        dismiss()
                    }
                    .buttonStyle(ToastButtonStyle())
                    .help(link.absoluteString)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 56)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        }
        .padding(12)  // room for the shadows inside the panel
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6).delay(0.12)) { badgeShown = true }
        }
    }
}

/// Glint's capsule button: white 20%, darker on hover, darker still and slightly smaller while pressed.
private struct ToastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ToastButton(configuration: configuration)
    }

    private struct ToastButton: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(0.2)))
                .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.25 : hovered ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovered = $0 }
        }
    }
}
