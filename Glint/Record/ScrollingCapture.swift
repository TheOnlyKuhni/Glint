import AppKit
import SwiftUI

/// "Scrolling Capture": select the scrolling part of a window, press Start Capture, then scroll
/// (or let Auto-Scroll do it). The toggle on the area's right edge switches to sideways scrolling before you start.
/// Frames are matched by row (or column) fingerprints and stitched into one tall (or wide) screenshot, with a live
/// preview next to the area. Done delivers it like any screenshot.
final class ScrollingCapture {
    static let shared = ScrollingCapture()

    private var selector: RegionSelector?
    private var run: ScrollingRun?

    /// `initial` (from All-In-One) starts with that area already selected.
    func start(initial: CGRect? = nil) {
        if selector != nil || run != nil { CLIReply.send("busy") }
        guard selector == nil, run == nil, Permissions.ensureScreenRecording() else { return }
        guard Defaults[Prefs.scrollingTutorialSeen] else {
            ScrollingTutorial.show { [weak self] in
                Defaults[Prefs.scrollingTutorialSeen] = true
                self?.start(initial: initial)
            }
            return
        }
        let selector = RegionSelector(hint: "Drag to capture the scrolling part of the screen.")
        selector.onCancel = { [weak self] in self?.selector = nil; CLIReply.cancelled() }
        selector.onConfirm = { [weak self] _ in self?.begin() }
        let host = NSHostingView(rootView: StartCaptureRow(start: { [weak self] in self?.begin() },
                                                           help: { [weak selector] in
                                                               ScrollingTutorial.show(onFinish: nil, returningTo: selector?.overlayView.window)
                                                           }))
        host.sizingOptions = [.intrinsicContentSize]
        selector.setAccessory(host, placement: .bottomInside)
        self.selector = selector
        selector.begin(initial: initial)
    }

    private func begin() {
        guard let selector, !selector.rect.isEmpty else { return }
        let rect = selector.rect, screen = selector.screen
        selector.end()
        self.selector = nil
        let run = ScrollingRun(rect: rect, screen: screen)
        run.onFinish = { [weak self] in self?.run = nil }
        self.run = run
        run.begin()
    }
}

/// "↓ Start Capture" (light pill) and the "?" help button.
private struct StartCaptureRow: View {
    let start: () -> Void
    let help: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Button(action: start) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down").font(.system(size: 13, weight: .semibold))
                    Text("Start Capture").font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(Color(white: 0.12))
                .padding(.horizontal, 15)
                .frame(height: 32)
                .background(Capsule().fill(Color(white: 0.9)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Button(action: help) {
                Image(systemName: "questionmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color(white: 0.2))
                    .frame(width: 24, height: 24).background(Circle().fill(Color(white: 0.9)))
            }
            .buttonStyle(.plain).help("How it works")
        }
        .fixedSize()
    }
}

// MARK: - A running capture

final class ScrollingRunModel: ObservableObject {
    @Published var preview: NSImage?
    @Published var horizontal = false
}

final class ScrollingRun {
    let rect: CGRect
    let screen: NSScreen
    var onFinish: (() -> Void)?

    private let model = ScrollingRunModel()
    private let stitcher = Stitcher()
    private var frameWindow: NSWindow?
    private var controls: NSPanel?
    private var previewPanel: NSPanel?
    private var autoScrollPanel: NSPanel?
    private var sideToggle: NSPanel?
    private var pauseHint: NSPanel?
    private var captureTask: Task<Void, Never>?
    private var scrollTimer: DispatchSourceTimer?
    private var autoScrolling = false
    private var finished = false

    init(rect: CGRect, screen: NSScreen) {
        self.rect = rect
        self.screen = screen
    }

    private var appKitRect: CGRect { Geometry.appKitRect(fromCG: rect) }

    func begin() {
        stitcher.lock(horizontal: false)
        showFrame()
        showControls()
        showPreview()
        ShortcutManager.shared.setEscapeHandler { [weak self] in self?.finish(save: false) }
        captureTask = Task { [weak self] in
            // Let the selection overlay leave the screen before the first frame.
            try? await Task.sleep(for: .milliseconds(200))
            while let self, !self.finished {
                if let image = try? await ScreenCapturer.capture(rect: self.rect, on: self.screen) {
                    if self.stitcher.add(image) { self.updatePreview() }
                    // The direction can't change once the content moved: the side toggle goes away.
                    if self.stitcher.hasScrolled, self.sideToggle?.isVisible == true { self.fadeOut(self.sideToggle) }
                }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private var lastPreview = Date.distantPast

    /// At most every 0.4s: the preview re-stitches the whole capture.
    private func updatePreview() {
        guard Date().timeIntervalSince(lastPreview) > 0.4 else { return }
        lastPreview = Date()
        let maxSize = model.horizontal ? CGSize(width: 2000, height: 300) : CGSize(width: 600, height: 20_000)
        guard let image = stitcher.preview(fitting: maxSize) else { return }
        model.preview = NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        if !model.horizontal { layoutVerticalPreview(aspect: CGFloat(image.height) / CGFloat(max(image.width, 1))) }
    }

    private var previewOnRight = true

    /// The vertical preview is exactly the capture's shape: 300pt wide, growing upward from the area's bottom edge
    /// until it reaches the menu bar; after that it keeps that height and gets narrower as the capture grows.
    private func layoutVerticalPreview(aspect: CGFloat) {
        guard let previewPanel else { return }
        let area = appKitRect
        let maxHeight = screen.visibleFrame.maxY - area.minY
        var size = CGSize(width: 300, height: 300 * aspect)
        if size.height > maxHeight { size = CGSize(width: max(maxHeight / aspect, 24), height: maxHeight) }
        let x = previewOnRight ? area.maxX + 10 : area.minX - 10 - size.width
        let frame = CGRect(x: x, y: area.minY, width: size.width, height: size.height).integral
        guard frame != previewPanel.frame else { return }
        previewPanel.setFrame(frame, display: true)
        previewPanel.contentView?.frame = CGRect(origin: .zero, size: frame.size)
    }

    /// The Auto-Scroll, logged event by event: one continuous (pixel) scroll of 61pt every 0.15 s, posted at
    /// the pointer, so the content moves in even steps (~400pt/s). It only scrolls while the pointer is inside the
    /// area; outside it pauses and a hint asks to move the pointer back. The pill and the side toggle go away.
    func startAutoScroll() {
        guard !autoScrolling,
              AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) else { return }
        autoScrolling = true
        fadeOut(autoScrollPanel)
        fadeOut(sideToggle)
        scrollTimer = Self.autoScrollTimer(area: rect, horizontal: model.horizontal) { [weak self] inside in
            Task { @MainActor in self?.pointerInside(inside) }
        }
    }

    private var pointerWasInside: Bool?

    private func pointerInside(_ inside: Bool) {
        guard inside != pointerWasInside, !finished else { return }
        pointerWasInside = inside
        if inside { fadeOut(pauseHint) } else { showPauseHint() }
    }

    /// Runs off the main thread (stitching keeps it busy), so the steps stay evenly spaced.
    private nonisolated static func autoScrollTimer(area: CGRect, horizontal: Bool, pointer: @escaping @Sendable (Bool) -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: DispatchQueue(label: "com.philippk.glint.autoscroll", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(150), leeway: .milliseconds(1))
        timer.setEventHandler {
            guard let mouse = CGEvent(source: nil)?.location else { return }
            let inside = area.contains(mouse)
            pointer(inside)
            guard inside, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                              wheel1: horizontal ? 0 : -61, wheel2: horizontal ? -61 : 0, wheel3: 0)
            else { return }
            // Without a location the event only reaches the frontmost app; posted with one, they land under the pointer.
            event.location = mouse
            event.post(tap: .cghidEventTap)
        }
        timer.resume()
        return timer
    }

    /// The side toggle: capture sideways (manual scrolling only, so Auto-Scroll goes away).
    func switchToHorizontal() {
        guard !stitcher.hasScrolled, !autoScrolling else { return }
        model.horizontal = true
        stitcher.lock(horizontal: true)
        // Auto-Scroll stays available sideways (it scrolls right).
        fadeOut(sideToggle)
        previewPanel?.orderOut(nil)
        showPreview()
        lastPreview = .distantPast
        updatePreview()
    }

    func finish(save: Bool) {
        guard !finished else { return }
        finished = true
        captureTask?.cancel()
        scrollTimer?.cancel()
        ShortcutManager.shared.setEscapeHandler(nil)
        for window in [frameWindow, controls, previewPanel, autoScrollPanel, sideToggle, pauseHint] { window?.orderOut(nil) }
        if !save { CLIReply.cancelled() }
        if save {
            if let image = stitcher.result() {
                CaptureOutput.deliver(image, scale: screen.backingScaleFactor)
            } else {
                NSSound.beep()
            }
        }
        onFinish?()
    }

    // MARK: Windows

    private func panel(_ frame: CGRect, level: NSWindow.Level = .statusBar) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = level
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    /// Dims around the area and keeps its brackets; clicks and scrolling pass through.
    private func showFrame() {
        let window = panel(screen.frame, level: .floating)
        window.ignoresMouseEvents = true
        let view = AreaFrameView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.area = appKitRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        window.contentView = view
        window.orderFrontRegardless()
        frameWindow = window
    }

    /// A SwiftUI view in its own panel, sized to fit.
    private func panel<V: View>(_ view: V, at origin: (CGSize) -> CGPoint) -> NSPanel {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = panel(CGRect(origin: origin(size), size: size))
        host.frame = CGRect(origin: .zero, size: size)
        panel.contentView = host
        panel.orderFrontRegardless()
        return panel
    }

    /// Cancel / Done 15pt below the area (inside its bottom when there's no room), the Auto-Scroll
    /// pill inside the area 15pt above its bottom, and the side toggle inside the right edge, centered.
    private func showControls() {
        let area = appKitRect, visible = screen.visibleFrame
        var buttonsTop = area.minY - 15
        controls = panel(ScrollingButtons(cancel: { [weak self] in self?.finish(save: false) },
                                          done: { [weak self] in self?.finish(save: true) })) { size in
            if buttonsTop - size.height < visible.minY { buttonsTop = area.minY + 15 + size.height }
            return CGPoint(x: area.midX - size.width / 2, y: buttonsTop - size.height)
        }
        let pillBottom = buttonsTop > area.minY ? buttonsTop + 12 : area.minY + 15
        autoScrollPanel = panel(AutoScrollPill { [weak self] in self?.startAutoScroll() }) { size in
            CGPoint(x: area.midX - size.width / 2, y: pillBottom)
        }
        sideToggle = panel(SideScrollToggle { [weak self] in self?.switchToHorizontal() }) { size in
            CGPoint(x: area.maxX - 15 - size.width, y: area.midY - size.height / 2)
        }
    }

    private func showPauseHint() {
        if pauseHint == nil {
            let area = appKitRect
            pauseHint = panel(PauseHint()) { CGPoint(x: area.midX - $0.width / 2, y: area.midY - $0.height / 2) }
            pauseHint?.ignoresMouseEvents = true
            pauseHint?.alphaValue = 0
        }
        guard let pauseHint, pauseHint.alphaValue < 1 || !pauseHint.isVisible else { return }
        pauseHint.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; pauseHint.animator().alphaValue = 1 }
    }

    private func fadeOut(_ panel: NSPanel?) {
        guard let panel, panel.isVisible, panel.alphaValue > 0 else { return }
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 },
                                            completionHandler: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
    }

    /// Vertical: 300pt wide beside the area (right, or left when there's no room), aligned to its bottom.
    /// Horizontal: a strip inside the area's bottom-right corner.
    private func showPreview() {
        let area = appKitRect, visible = screen.visibleFrame
        let frame: CGRect
        if model.horizontal {
            let size = CGSize(width: area.width - 30, height: min(150, area.height / 3))
            frame = CGRect(x: area.maxX - 15 - size.width, y: area.minY + 15, width: size.width, height: size.height)
        } else {
            // Starts with the area's own shape; `layoutVerticalPreview` grows it with the capture.
            let size = CGSize(width: 300, height: min(300 * area.height / max(area.width, 1), visible.maxY - area.minY))
            previewOnRight = area.maxX + 10 + size.width <= visible.maxX
            let x = previewOnRight ? area.maxX + 10 : area.minX - 10 - size.width
            frame = CGRect(x: x, y: area.minY, width: size.width, height: size.height)
        }
        let panel = panel(frame)
        panel.hasShadow = true
        // Scrolling over the preview (it sits inside the area sideways) reaches the content below.
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: ScrollingPreview(model: model))
        host.frame = CGRect(origin: .zero, size: frame.size)
        panel.contentView = host
        panel.orderFrontRegardless()
        previewPanel = panel
    }
}

/// The light Auto-Scroll pill (a dark circle with a down triangle).
private struct AutoScrollPill: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 15, height: 15).background(Circle().fill(Color(white: 0.15)))
                Text("Auto-Scroll").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.12))
            }
            .padding(.leading, 5).padding(.trailing, 11)
            .frame(height: 24)
            .background(Capsule().fill(Color(white: 0.88)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// The side-scroll toggle on the area's right edge: a light 24×46pt capsule with a dark "play" circle.
private struct SideScrollToggle: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill").font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
                .offset(x: 0.5)
                .frame(width: 16, height: 16).background(Circle().fill(Color(white: 0.15)))
                .frame(width: 24, height: 46)
                .background(Capsule().fill(Color(white: 0.88)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Scroll horizontally")
        .fixedSize()
    }
}

/// Shown in the middle of the area while Auto-Scroll waits for the pointer.
private struct PauseHint: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "pause.fill").font(.system(size: 6, weight: .bold)).foregroundStyle(.white)
                .frame(width: 15, height: 15).background(Circle().fill(Color(white: 0.15)))
            Text("Move cursor here to start scrolling").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(white: 0.12))
        }
        .padding(.leading, 7).padding(.trailing, 14)
        .frame(height: 32)
        .background(Capsule().fill(Color(white: 0.88)))
        .fixedSize()
    }
}

/// Cancel (dark) and Done (light) pills.
private struct ScrollingButtons: View {
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            pill("xmark", "Cancel", light: false, action: cancel)
            pill("checkmark", "Done", light: true, action: done)
        }
        .padding(4)
        .fixedSize()
    }

    private func pill(_ symbol: String, _ title: String, light: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(light ? Color(white: 0.12) : .white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Capsule().fill(light ? Color(white: 0.9) : Color(white: 0.17)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ScrollingPreview: View {
    @ObservedObject var model: ScrollingRunModel
    var body: some View {
        ZStack(alignment: .bottom) {
            // Vertically the panel has the capture's shape, so the image fills it (no empty area). Sideways it's
            // just the thumbnail in the area's corner.
            if let preview = model.preview {
                // The newest part stays in view: the right end (horizontal).
                Image(nsImage: preview).resizable().aspectRatio(contentMode: model.horizontal ? .fit : .fill)
                    .clipShape(RoundedRectangle(cornerRadius: model.horizontal ? 4 : 0, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.horizontal ? .bottomTrailing : .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Dimmed surroundings with the area's corner brackets (AppKit coordinates).
private final class AreaFrameView: NSView {
    var area: CGRect = .zero
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addRect(bounds)
        ctx.addRect(area)
        ctx.fillPath(using: .evenOdd)
        let r = area, t: CGFloat = 3, arm: CGFloat = 16
        ctx.setFillColor(NSColor.white.cgColor)
        for (x, y, sx, sy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0), (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            ctx.fill(CGRect(x: sx > 0 ? x - t : x - arm + t, y: sy > 0 ? y - t : y, width: arm, height: t).standardized)
            ctx.fill(CGRect(x: sx > 0 ? x - t : x, y: sy > 0 ? y - t : y - arm + t, width: t, height: arm).standardized)
        }
    }
}

// MARK: - Stitching

/// Finds how far each new frame scrolled relative to the last one and keeps only the new strip.
/// Matching uses per-row (or per-column) fingerprints: identical content gives identical fingerprints,
/// and the offset with the most votes wins. The direction is fixed by the first movement.
/// Each line is fingerprinted in several bands across the frame, so an animation or a fixed sidebar in one part
/// only spoils that band's votes instead of every row.
final class Stitcher {
    private enum Axis { case vertical, horizontal }
    private var axis: Axis?
    private var last: Frame?
    /// The first frame, then each new strip (pixels to append along the axis).
    private var pieces: [(image: CGImage, newPixels: Int)] = []

    /// True once the content moved (the direction is settled).
    var hasScrolled: Bool { pieces.count > 1 }

    /// Only look for movement along one axis.
    func lock(horizontal: Bool) { axis = horizontal ? .horizontal : .vertical }

    private struct Frame {
        let image: CGImage
        /// Per band, the fingerprint of every row (column).
        let rows: [[UInt64]]
        let columns: [[UInt64]]
    }

    private static let bands = 5

    /// Returns true when the stitched result grew.
    func add(_ image: CGImage) -> Bool {
        guard let frame = Self.frame(image) else { return false }
        guard let last else {
            self.last = frame
            pieces = [(image, image.height)]
            return true
        }
        guard last.image.width == image.width, last.image.height == image.height else { return false }
        let dy = axis != .horizontal ? Self.offset(last.rows, frame.rows) : nil
        let dx = axis != .vertical ? Self.offset(last.columns, frame.columns) : nil
        let pick: (Axis, Int)? = switch (dy, dx) {
        case let (y?, x?): y >= x ? (.vertical, y) : (.horizontal, x)
        case let (y?, nil): (.vertical, y)
        case let (nil, x?): (.horizontal, x)
        default: nil
        }
        guard let (direction, moved) = pick, moved > 0 else { return false }
        axis = direction
        if pieces.count == 1 { pieces[0].newPixels = direction == .vertical ? image.height : image.width }
        pieces.append((image, moved))
        self.last = frame
        return true
    }

    /// The scroll distance (> 0 = content moved forward) with the most matching fingerprints over all bands,
    /// if convincing. Lines that stayed in place (fixed headers, sidebars) don't count against it.
    private static func offset(_ previous: [[UInt64]], _ current: [[UInt64]]) -> Int? {
        var votes: [Int: Int] = [:]
        var moving = 0
        for (prev, cur) in zip(previous, current) {
            var counts: [UInt64: Int] = [:]
            for v in prev where v != 0 { counts[v, default: 0] += 1 }
            var positions: [UInt64: Int] = [:]
            for (i, v) in prev.enumerated() where counts[v] == 1 { positions[v] = i }
            for (i, v) in cur.enumerated() where v != 0 {
                guard let j = positions[v], j != i else { continue }
                moving += 1
                if j > i { votes[j - i, default: 0] += 1 }
            }
        }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= max(6, moving / 4) else { return nil }
        return best.key
    }

    /// Fingerprints of every row and column (a hash of sampled pixels; 0 for flat lines, which can't be matched).
    private static func frame(_ image: CGImage) -> Frame? {
        let w = image.width, h = image.height
        guard w > 8, h > 8, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt32.self) else { return nil }
        func hash(_ range: Range<Int>, _ step: Int, _ pixel: (Int) -> UInt32) -> UInt64 {
            var hv: UInt64 = 1469598103934665603
            var first: UInt32?, flat = true
            for k in stride(from: range.lowerBound, to: range.upperBound, by: step) {
                let p = pixel(k) & 0x00FF_FFFF
                if let f = first, f != p { flat = false } else if first == nil { first = p }
                hv = (hv ^ UInt64(p)) &* 1099511628211
            }
            return flat ? 0 : hv
        }
        func bands(_ count: Int) -> [Range<Int>] {
            (0..<Self.bands).map { b in count * b / Self.bands..<count * (b + 1) / Self.bands }
        }
        // Context rows are stored top-down.
        let rows = bands(w).map { band in (0..<h).map { y in hash(band, 2) { x in data[y * w + x] } } }
        let columns = bands(h).map { band in (0..<w).map { x in hash(band, 2) { y in data[y * w + x] } } }
        return Frame(image: image, rows: rows, columns: columns)
    }

    func result(maxLength: Int = 32_000) -> CGImage? {
        guard let first = pieces.first?.image else { return nil }
        let vertical = axis != .horizontal
        let extra = pieces.dropFirst().reduce(0) { $0 + $1.newPixels }
        let w = vertical ? first.width : min(first.width + extra, maxLength)
        let h = vertical ? min(first.height + extra, maxLength) : first.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: first.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Each piece is drawn so its last `newPixels` land right after what's already there.
        var end = vertical ? first.height : first.width
        ctx.draw(first, in: vertical ? CGRect(x: 0, y: h - first.height, width: first.width, height: first.height)
                                     : CGRect(x: 0, y: 0, width: first.width, height: first.height))
        for piece in pieces.dropFirst() {
            end += piece.newPixels
            if vertical {
                let top = end - piece.image.height
                ctx.draw(piece.image, in: CGRect(x: 0, y: h - top - piece.image.height, width: piece.image.width, height: piece.image.height))
            } else {
                ctx.draw(piece.image, in: CGRect(x: end - piece.image.width, y: 0, width: piece.image.width, height: piece.image.height))
            }
            if end >= (vertical ? h : w) { break }
        }
        return ctx.makeImage()
    }

    /// The stitched image scaled down to fit `maxSize` pixels (for the live preview).
    func preview(fitting maxSize: CGSize) -> CGImage? {
        guard let full = result() else { return nil }
        let scale = min(1, maxSize.width / CGFloat(full.width), maxSize.height / CGFloat(full.height))
        return ImageProcessing.resized(full, to: CGSize(width: CGFloat(full.width) * scale, height: CGFloat(full.height) * scale))
    }
}

// MARK: - Tutorial

/// The first-run guide: how to select, both directions, scroll slowly, troubleshooting → Start capturing.
enum ScrollingTutorial {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    /// Opens above everything (also the area picker, whose window gets the keyboard back afterwards).
    static func show(onFinish: (() -> Void)?, returningTo previous: NSWindow? = nil) {
        window?.close()
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 450), styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: TutorialView { [weak w] in
            w?.close()
            onFinish?()
        })
        host.sizingOptions = []
        w.contentView = host
        w.setFrame(CGRect(x: 0, y: 0, width: 600, height: 450), display: false)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if let previous {
            closeObserver.map(NotificationCenter.default.removeObserver)
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                previous.makeKeyAndOrderFront(nil)
            }
        }
        w.center()
        NSApp.bringToFront()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    private struct Page {
        let title: String
        let text: String
        let samples: [(Sample, Bool)]
    }

    private enum Sample { case inside, withEdge, wholeWindow, down, right, both, slow, fast }

    private static let pages = [
        Page(title: "How to select an area?",
             text: "Only scrollable content should be selected. Any non-moving parts or scroll bar should not be present in your selection.",
             samples: [(.inside, true), (.withEdge, false), (.wholeWindow, false)]),
        Page(title: "Scroll Vertically or Horizontally",
             text: "You can capture content in both vertical and horizontal orientations, but you can't switch directions during capture.",
             samples: [(.down, true), (.right, true), (.both, false)]),
        Page(title: "Slowly scroll down the content",
             text: "You'll see a preview of your screenshot updated in real time. Scrolling too fast might result in breaking the capture process.",
             samples: [(.slow, true), (.fast, false)]),
    ]

    private struct TutorialView: View {
        let finish: () -> Void
        @State private var page = 0

        var body: some View {
            VStack(spacing: 0) {
                if page < pages.count {
                    let p = pages[page]
                    Text(p.title).font(.system(size: 28, weight: .bold)).padding(.top, 52)
                    Text(p.text).font(.system(size: 15)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(width: 470).padding(.top, 14)
                    HStack(spacing: 22) {
                        ForEach(p.samples.indices, id: \.self) { i in
                            VStack(spacing: 14) {
                                SampleView(sample: p.samples[i].0)
                                Image(systemName: p.samples[i].1 ? "checkmark.circle" : "xmark.circle")
                                    .font(.system(size: 20)).foregroundStyle(p.samples[i].1 ? .green : .red)
                            }
                        }
                    }
                    .padding(.top, 38)
                    Spacer()
                    button("Next") { page += 1 }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Troubleshooting").font(.system(size: 28, weight: .bold))
                        Text("Currently, the following conditions may break the scrolling capture:").font(.system(size: 15)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(["When selected area contains animations or videos.",
                                     "When you are not scrolling entirely vertically or horizontally.",
                                     "When you are scrolling too fast.", "When you start scrolling up."], id: \.self) {
                                Text("•  " + $0).font(.system(size: 15))
                            }
                        }
                        .padding(.top, 30)
                    }
                    .frame(width: 480, alignment: .leading)
                    .padding(.top, 74)
                    Spacer()
                    button("Start capturing", action: finish)
                }
            }
            .padding(.bottom, 26)
            .frame(width: 600, height: 450)
        }

        private func button(_ title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 36)
                    .background(Capsule().fill(Color(.displayP3, red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// A tiny window on a wallpaper-ish card, with the selection (blue) or the scroll direction drawn in.
    private struct SampleView: View {
        let sample: Sample
        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [Color(white: 0.35), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) { ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 4, height: 4) } }
                        .padding(5).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.5))
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(0..<5, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2).fill(Color(white: sample == .fast ? 0.75 : 0.6))
                                .frame(width: [70, 40, 80, 55, 35][i], height: 4).blur(radius: sample == .fast ? 1.5 : 0)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(white: 0.93))
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 112, height: 86)
                .overlay(selection)
                overlayArrow
            }
            .frame(width: 166, height: 128)
        }

        @ViewBuilder private var selection: some View {
            switch sample {
            case .inside: RoundedRectangle(cornerRadius: 2).stroke(Color.blue, lineWidth: 2).padding(EdgeInsets(top: 20, leading: 6, bottom: 8, trailing: 6))
            case .withEdge: RoundedRectangle(cornerRadius: 2).stroke(Color.blue, lineWidth: 2).padding(EdgeInsets(top: 20, leading: 6, bottom: -2, trailing: -2))
            case .wholeWindow: RoundedRectangle(cornerRadius: 4).stroke(Color.blue, lineWidth: 2).padding(-2)
            default: EmptyView()
            }
        }

        @ViewBuilder private var overlayArrow: some View {
            switch sample {
            case .down: Image(systemName: "arrow.down").font(.system(size: 24, weight: .bold)).foregroundStyle(.black)
            case .right: Image(systemName: "arrow.right").font(.system(size: 24, weight: .bold)).foregroundStyle(.black)
            case .both: Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 24, weight: .bold)).foregroundStyle(.black)
            default: EmptyView()
            }
        }
    }
}
