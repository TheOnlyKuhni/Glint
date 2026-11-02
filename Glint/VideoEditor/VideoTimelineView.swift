import AppKit
import AVFoundation
import Combine

/// The timeline: seconds ruler, red playhead, a 30pt zoom track ("+ Click or drag to add zoom")
/// and the 60pt clip of thumbnails, 26pt in from both sides. Drag the clip's edges to trim (a "✂ 0.8s" marker shows
/// what was cut; click it to bring it back), with the scissors click to split or drag across a stretch to cut it out,
/// click a clip and press ⌫ to delete it. Zooms: click or drag on the zoom track to add one, drag to move, drag its ends to resize, ⌫ deletes.
final class VideoTimelineView: NSView {
    let scrollView = NSScrollView()
    private let project: VideoProject
    private let state: VideoEditorState
    private var thumbnails: [(time: Double, image: CGImage)] = []
    /// While the zoom slider is dragged: the scale it started at (tiles stretch from there).
    private var stretchFrom: CGFloat?
    private var subscriptions: [AnyCancellable] = []

    private enum Metrics {
        static let inset: CGFloat = 26
        static let rulerText: CGFloat = 18.5
        static let headTop: CGFloat = 28
        static let zoomTop: CGFloat = 79
        static let zoomHeight: CGFloat = 30
        static let clipTop: CGFloat = 122
        static let clipHeight: CGFloat = 60
        static let cutTop: CGFloat = 190
    }

    private static let red = NSColor(red: 0xE9 / 255.0, green: 0x5F / 255.0, blue: 0x52 / 255.0, alpha: 1)
    private static let blue = NSColor(displayP3Red: 0x34 / 255.0, green: 0x78 / 255.0, blue: 0xF6 / 255.0, alpha: 1)
    private static let track = NSColor(white: 0x21 / 255.0, alpha: 1)

    init(project: VideoProject, state: VideoEditorState) {
        self.project = project
        self.state = state
        super.init(frame: CGRect(x: 0, y: 0, width: 1180, height: 258))
        scrollView.documentView = self
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0x17 / 255.0, alpha: 1)
        scrollView.verticalScrollElasticity = .none
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsFrameChangedNotifications = true
        subscriptions = [
            state.$time.sink { [weak self] _ in DispatchQueue.main.async { self?.playheadMoved() } },
            state.$timelineZoom.sink { [weak self] _ in DispatchQueue.main.async { self?.resize() } },
            state.$selectedZoom.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } },
            state.$selectedCut.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } },
            state.$selectedClip.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } },
            state.$timelineZoomEditing.sink { [weak self] editing in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.stretchFrom = editing ? self.pointsPerSecond : nil
                    self.needsDisplay = true
                }
            },
            state.$scissors.sink { [weak self] on in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !on { self.hoverCut = nil; self.cutPreview = nil }
                    self.window?.invalidateCursorRects(for: self)
                    // Swap the pointer right away if it's over the timeline.
                    if let window = self.window {
                        let p = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                        if self.visibleRect.contains(p) { self.updateCursor(p) }
                    }
                    self.needsDisplay = true
                }
            },
        ]
        Task { await makeThumbnails() }
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refresh() {
        resize()
        needsDisplay = true
    }

    @objc private func clipResized() { resize() }

    // MARK: Geometry

    private var visibleWidth: CGFloat { scrollView.contentView.bounds.width }
    private var tile: CGFloat {
        Metrics.clipHeight * (project.sourceSize.width > 0 ? project.sourceSize.width / project.sourceSize.height : 16 / 9)
    }
    /// The +/− slider's range (log scale): one thumbnail tile per 2 minutes (but at least one whole frame for the
    /// clip) … one tile per frame.
    private var ppsRange: (min: CGFloat, max: CGFloat) {
        (max(tile / 120, tile / CGFloat(max(project.sourceDuration, 0.01))), tile * CGFloat(max(project.frameRate, 1)))
    }
    private var fitPPS: CGFloat { max(visibleWidth - Metrics.inset * 2, 100) / CGFloat(max(project.sourceDuration, 0.5)) }
    private var pointsPerSecond: CGFloat {
        let r = ppsRange
        return r.min * pow(r.max / r.min, CGFloat(state.timelineZoom))
    }
    private var zoomInitialized = false
    private func x(_ t: Double) -> CGFloat { Metrics.inset + CGFloat(t) * pointsPerSecond }
    private func time(_ x: CGFloat) -> Double { Double((x - Metrics.inset) / pointsPerSecond) }

    private func resize() {
        // The slider starts where the whole clip fits.
        if !zoomInitialized, visibleWidth > 0, project.sourceDuration > 0 {
            zoomInitialized = true
            let r = ppsRange
            state.timelineZoom = Double(min(max(log(fitPPS / r.min) / log(r.max / r.min), 0), 1))
            return
        }
        let width = max(visibleWidth, x(project.sourceDuration) + Metrics.inset)
        let height = scrollView.contentView.bounds.height
        if frame.size != CGSize(width: width, height: height) { setFrameSize(CGSize(width: width, height: max(height, 230))) }
        needsDisplay = true
    }

    private var lastPlayheadX: CGFloat = 0
    private var autoScrolling = false

    private func playheadMoved() {
        let px = x(state.time)
        setNeedsDisplay(CGRect(x: lastPlayheadX - 8, y: 0, width: 16, height: bounds.height))
        setNeedsDisplay(CGRect(x: px - 8, y: 0, width: 16, height: bounds.height))
        lastPlayheadX = px
        // Keep the playhead in view while playing: at the right edge the strip glides left (0.4 s) so the playhead
        // continues near the left side.
        if state.isPlaying, !autoScrolling {
            let visible = scrollView.contentView.bounds
            if px > visible.maxX - 40 {
                let target = min(px - Metrics.inset - 20, bounds.width - visible.width)
                autoScrolling = true
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    scrollView.contentView.animator().setBoundsOrigin(CGPoint(x: max(target, 0), y: visible.minY))
                }, completionHandler: { [weak self] in
                    self?.autoScrolling = false
                    if let sv = self?.scrollView { sv.reflectScrolledClipView(sv.contentView) }
                })
            }
        }
    }

    /// Scrolls so the playhead at `t` is in view (the start/end of the clip lands at its edge).
    func reveal(_ t: Double) {
        let visible = scrollView.contentView.bounds
        let px = x(t)
        guard px < visible.minX + 20 || px > visible.maxX - 20 else { return }
        let target = t <= 0.001 ? 0 : min(max(px - visible.width / 2, 0), max(bounds.width - visible.width, 0))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            scrollView.contentView.animator().setBoundsOrigin(CGPoint(x: target, y: visible.minY))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func zoomRect(_ z: VideoZoom) -> CGRect {
        CGRect(x: x(z.start), y: Metrics.zoomTop, width: x(z.end) - x(z.start), height: Metrics.zoomHeight)
    }

    private func clipRects() -> [(VideoClip, CGRect)] {
        zip(project.clips, project.clipStarts).map { clip, start in
            (clip, CGRect(x: x(start), y: Metrics.clipTop, width: CGFloat(clip.duration) * pointsPerSecond, height: Metrics.clipHeight))
        }
    }

    /// A cut marker under the clip: scissors, plus the removed length when something was cut out.
    private func cutRect(_ cut: (at: Double, length: Double)) -> CGRect {
        var w: CGFloat = 26
        if cut.length > 0 {
            let text = Self.cutLabel(cut.length) as NSString
            w = text.size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 30
        }
        return CGRect(x: x(cut.at) - w / 2, y: Metrics.cutTop, width: w, height: 20)
    }

    private func cutMarker(at p: CGPoint) -> (at: Double, length: Double)? {
        project.cuts.first { cutRect($0).insetBy(dx: -2, dy: -2).contains(p) }
    }

    private func isSelected(_ cut: (at: Double, length: Double)) -> Bool {
        state.selectedCut.map { abs($0 - cut.at) < 0.001 } ?? false
    }

    private static func cutLabel(_ length: Double) -> String { String(format: "%.1fs", length) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0x17 / 255.0, alpha: 1).setFill()
        dirtyRect.fill()
        drawRuler()
        drawZoomTrack()
        drawClips()
        drawCuts()
        drawPlayhead()
        drawScissors()
        updateToolTips()
    }

    // MARK: Hover hints

    /// One tooltip area per ruler, zoom-track gap, zoom, clip and cut marker; the text comes from the point (so it
    /// follows the cut tool). Areas are only rebuilt when they move, otherwise redraws during playback would keep
    /// restarting the 1 s delay.
    private var toolTipRects: [CGRect] = []

    private func updateToolTips() {
        var rects = [CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.zoomTop - 4)]
        var gapStart = Metrics.inset
        for r in project.zooms.map(zoomRect).sorted(by: { $0.minX < $1.minX }) {
            if r.minX > gapStart { rects.append(CGRect(x: gapStart, y: Metrics.zoomTop, width: r.minX - gapStart, height: Metrics.zoomHeight)) }
            rects.append(r)
            gapStart = max(gapStart, r.maxX)
        }
        let end = x(project.duration)
        if end > gapStart { rects.append(CGRect(x: gapStart, y: Metrics.zoomTop, width: end - gapStart, height: Metrics.zoomHeight)) }
        rects += clipRects().map(\.1)
        rects += project.cuts.map(cutRect)
        guard rects != toolTipRects else { return }
        toolTipRects = rects
        removeAllToolTips()
        for r in rects { addToolTip(r, owner: self, userData: nil) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if let cut = cutMarker(at: point) {
            let what = cut.length > 0 ? "\(Self.cutLabel(cut.length)) cut out" : "Cut"
            return "\(what): click to select, ⌫ or right-click → Delete Cut removes it"
        }
        if let hit = zoomHit(point) {
            return "Zoom \(Int((hit.zoom.scale * 100).rounded()))%: drag to move, drag its ends to resize, right-click for more, ⌫ removes it"
        }
        if point.y >= Metrics.zoomTop, point.y <= Metrics.zoomTop + Metrics.zoomHeight {
            return "Click to add a zoom, or drag to add one over a stretch"
        }
        if point.y >= Metrics.clipTop, point.y <= Metrics.clipTop + Metrics.clipHeight {
            return state.scissors
                ? "Click to split the clip here, drag across it to cut that part out (Esc leaves the cut tool)"
                : "Click to select (⌫ deletes it), drag its ends to trim, right-click to split"
        }
        return "Click or drag to move the playhead"
    }

    private func rulerStep() -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { CGFloat($0) * pointsPerSecond >= 110 } ?? 600
    }

    private func drawRuler() {
        let step = rulerStep()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
                                                    .foregroundColor: NSColor(white: 0.85, alpha: 1)]
        var t = 0.0
        while t <= project.sourceDuration + 0.001 {
            let px = x(t)
            NSColor(white: 1, alpha: 0.05).setFill()
            CGRect(x: px.rounded() - 0.5, y: Metrics.headTop + 8, width: 1, height: bounds.height).fill()
            let s = Int(t.rounded())
            let label = step < 1 && t.truncatingRemainder(dividingBy: 1) != 0
                ? String(format: "%02d:%04.1f", s / 60, t.truncatingRemainder(dividingBy: 60)) : String(format: "%02d:%02d", s / 60, s % 60)
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: CGPoint(x: px - size.width / 2, y: Metrics.rulerText - size.height / 2), withAttributes: attrs)
            t += step
        }
    }

    private func drawZoomTrack() {
        let end = x(project.duration)
        let track = CGRect(x: Metrics.inset, y: Metrics.zoomTop, width: end - Metrics.inset, height: Metrics.zoomHeight)
        Self.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8).fill()
        NSColor(white: 1, alpha: 0.04).setStroke()
        NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
        if let ghost = hoverZoom, drag == nil {
            let r = CGRect(x: x(ghost.start), y: Metrics.zoomTop, width: x(ghost.end) - x(ghost.start), height: Metrics.zoomHeight)
            NSColor(white: 0x33 / 255.0, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.62, alpha: 1)]
            let text = "+  Zoom" as NSString
            let size = text.size(withAttributes: attrs)
            if size.width + 12 < r.width { text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs) }
        } else if project.zooms.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.55, alpha: 1)]
            let text = "+  Click or drag to add zoom" as NSString
            let size = text.size(withAttributes: attrs)
            let visible = visibleRect.intersection(track)
            text.draw(at: CGPoint(x: (visible.isEmpty ? track : visible).midX - size.width / 2, y: track.midY - size.height / 2), withAttributes: attrs)
        }
        for z in project.zooms {
            let r = zoomRect(z)
            let selected = state.selectedZoom == z.id
            (selected ? Self.blue : NSColor(white: 0x3A / 255.0, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                        .foregroundColor: selected ? NSColor.white : NSColor(white: 0.7, alpha: 1)]
            let text = "Zoom \(Int((z.scale * 100).rounded()))%" as NSString
            let size = text.size(withAttributes: attrs)
            // Follow-cursor zooms carry a cursor symbol before the level.
            let icon = z.follow ? Self.followIcon(selected: selected) : nil
            let iconWidth: CGFloat = icon == nil ? 0 : 16
            if size.width + iconWidth + 12 < r.width {
                let x = r.midX - (size.width + iconWidth) / 2
                icon?.draw(in: CGRect(x: x, y: r.midY - 6.5, width: 12, height: 13))
                text.draw(at: CGPoint(x: x + iconWidth, y: r.midY - size.height / 2), withAttributes: attrs)
            } else if let icon, r.width > 18 {
                icon.draw(in: CGRect(x: r.midX - 6, y: r.midY - 6.5, width: 12, height: 13))
            }
        }
    }

    private func drawClips() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rects = clipRects()
        for (i, (clip, rect)) in rects.enumerated() {
            // Neighbouring clips get a small gap so splits are visible.
            let r = rect.insetBy(dx: rects.count > 1 ? 1 : 0, dy: 0)
            let path = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
            ctx.fill(r)
            /// `visible`: only the left part of the frame shows (it isn't squeezed).
            func drawTile(_ image: CGImage?, x: CGFloat, width: CGFloat, visible: CGFloat? = nil, dimmed: Bool = false) {
                guard let image, width > 0.5 else { return }
                ctx.saveGState()
                ctx.translateBy(x: x, y: r.maxY)
                ctx.scaleBy(x: 1, y: -1)
                if let visible { ctx.clip(to: CGRect(x: 0, y: 0, width: visible, height: Metrics.clipHeight)) }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: Metrics.clipHeight))
                if dimmed {
                    ctx.setFillColor(NSColor(white: 0.09, alpha: 0.7).cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: width, height: Metrics.clipHeight))
                }
                ctx.restoreGState()
            }
            if r.width < tile {
                // Fully zoomed out: the clip still shows one whole frame.
                drawTile(nearestThumbnail(clip.start), x: r.minX, width: r.width)
            } else if let from = stretchFrom {
                // While the +/− slider is dragged: frames never stretch. Zooming in, a new frame appears between each
                // pair, revealed from its left edge until it's whole (then there are twice as many); zooming out runs
                // it backwards, every second frame is cut away from its right until it's gone. On release the strip
                // is laid out again.
                let ratio = pointsPerSecond / from
                let k = floor(log2(ratio))
                let q = ratio / pow(2, k)                  // 1 ..< 2 within one doubling
                let reveal = (q - 1) * tile                // visible part of the in-between frame
                let span = Double(tile / (from * pow(2, k)))   // seconds per pair
                var x0 = r.minX, pair = 0.0
                while x0 < r.maxX {
                    let t0 = clip.start + pair * span
                    drawTile(nearestThumbnail(t0), x: x0, width: tile)
                    if reveal > 0.5 { drawTile(nearestThumbnail(t0 + span / 2), x: x0 + tile, width: tile, visible: reveal) }
                    x0 += tile + reveal
                    pair += 1
                }
            } else {
                var tx = r.minX
                var lastFrame = -1
                let rate = max(project.frameRate, 1)
                while tx < r.maxX {
                    // Each tile shows the first frame of the stretch it stands for. Zoomed past single frames, the
                    // repeats of a frame are dimmed so only its first tile stands out.
                    let raw = min(clip.start + Double((tx - r.minX) / pointsPerSecond), clip.end)
                    let frame = Int((raw * rate + 0.001).rounded(.down))
                    let t = min(Double(frame) / rate, clip.end)
                    if tx + tile > visibleRect.minX, tx < visibleRect.maxX { requestThumbnail(t, precision: max(Double(tile / pointsPerSecond) / 2, 0.5 / rate)) }
                    drawTile(nearestThumbnail(t), x: tx, width: tile, dimmed: frame == lastFrame && Double(tile / pointsPerSecond) < 1 / rate)
                    lastFrame = frame
                    tx += tile
                }
            }
            ctx.restoreGState()
            let selected = state.selectedClip == clip.id
            ctx.setStrokeColor(selected ? NSColor.white.cgColor : NSColor(white: 1, alpha: 0.08).cgColor)
            ctx.setLineWidth(selected ? 2 : 1)
            ctx.addPath(CGPath(roundedRect: r.insetBy(dx: selected ? 1 : 0.5, dy: selected ? 1 : 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
            ctx.strokePath()
            // Trim handles while hovering an edge.
            if let hover = hoverEdge, hover.clip == i {
                let hx = hover.leading ? r.minX + 7 : r.maxX - 7
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: hx - 2, y: r.midY - 20, width: 4, height: 40), cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.fillPath()
            }
        }
    }

    private func drawCuts() {
        for cut in project.cuts {
            // Gray pill like the zooms; selected = blue with white content. A short tick ties it to the cut.
            let r = cutRect(cut)
            let selected = isSelected(cut)
            let ink = selected ? NSColor.white : NSColor(white: 0.8, alpha: 1)
            (selected ? Self.blue : NSColor(white: 0x2E / 255.0, alpha: 1)).setFill()
            CGRect(x: x(cut.at).rounded() - 0.75, y: Metrics.clipTop + Metrics.clipHeight + 1, width: 1.5, height: r.minY - Metrics.clipTop - Metrics.clipHeight - 1).fill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
            let iconX = cut.length > 0 ? r.minX + 7 : r.midX - 6
            if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) {
                scissors.tinted(ink).draw(in: CGRect(x: iconX, y: r.midY - 5.5, width: 12, height: 11))
            }
            guard cut.length > 0 else { continue }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: ink]
            let text = Self.cutLabel(cut.length) as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: r.minX + 23, y: r.midY - size.height / 2), withAttributes: attrs)
        }
    }

    /// The cut tool: a white line where a click splits, or the red stretch a drag cuts out, with its length.
    private func drawScissors() {
        guard state.scissors else { return }
        let top = Metrics.clipTop - 6, height = Metrics.clipHeight + 12
        var label: String?
        var labelX: CGFloat = 0
        if let range = cutPreview, range.1 - range.0 > 0.05 {
            let r = CGRect(x: x(range.0), y: Metrics.clipTop, width: x(range.1) - x(range.0), height: Metrics.clipHeight)
            Self.red.withAlphaComponent(0.35).setFill()
            r.fill()
            Self.red.setFill()
            CGRect(x: r.minX - 1, y: top, width: 2, height: height).fill()
            CGRect(x: r.maxX - 1, y: top, width: 2, height: height).fill()
            label = "Cut " + Self.cutLabel(range.1 - range.0)
            labelX = r.midX
        } else if let t = hoverCut {
            let px = x(t).rounded()
            NSColor.white.setFill()
            CGRect(x: px - 1, y: top, width: 2, height: height).fill()
            label = Self.timeLabel(t)
            labelX = px
        }
        guard let label else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: labelX - size.width / 2 - 7, y: Metrics.clipTop + 5, width: size.width + 14, height: 18)
        NSColor(white: 0.2, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
        (label as NSString).draw(at: CGPoint(x: pill.minX + 7, y: pill.midY - size.height / 2), withAttributes: attrs)
    }

    private static func timeLabel(_ t: Double) -> String {
        String(format: "%02d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    private func drawPlayhead() {
        let px = x(state.time).rounded()
        Self.red.setFill()
        CGRect(x: px - 0.75, y: Metrics.headTop + 8, width: 1.5, height: bounds.height).fill()
        // The pin: a round head that narrows to a point on the line.
        NSBezierPath(ovalIn: CGRect(x: px - 6, y: Metrics.headTop, width: 12, height: 12)).fill()
        let point = NSBezierPath()
        point.move(to: CGPoint(x: px - 5, y: Metrics.headTop + 9))
        point.line(to: CGPoint(x: px + 5, y: Metrics.headTop + 9))
        point.line(to: CGPoint(x: px, y: Metrics.headTop + 16))
        point.close()
        point.fill()
    }

    // MARK: Thumbnails

    private func makeThumbnails() async {
        let generator = AVAssetImageGenerator(asset: project.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 120)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let duration = project.sourceDuration
        let count = max(2, min(160, Int(duration / 0.25)))
        for i in 0..<count {
            let t = duration * Double(i) / Double(count - 1)
            if let (image, _) = try? await generator.image(at: CMTime(seconds: min(t, max(duration - 0.05, 0)), preferredTimescale: 600)) {
                thumbnails.append((t, image))
                if i % 8 == 0 || i == count - 1 { needsDisplay = true }
            }
        }
        needsDisplay = true
    }

    private lazy var generator: AVAssetImageGenerator = {
        let generator = AVAssetImageGenerator(asset: project.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 120)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        return generator
    }()
    private var wanted: [Double] = []
    private var requested = Set<Int>()
    private var loading = false

    /// Queues a thumbnail for `t` unless one within `precision` seconds exists.
    private func requestThumbnail(_ t: Double, precision: Double) {
        guard precision < 0.2 else { return }
        if let near = thumbnails.min(by: { abs($0.time - t) < abs($1.time - t) }), abs(near.time - t) <= max(precision, 1.0 / 30) { return }
        let key = Int((t * 30).rounded())
        guard requested.insert(key).inserted else { return }
        wanted.append(t)
        loadNext()
    }

    private func loadNext() {
        guard !loading, !wanted.isEmpty else { return }
        loading = true
        let t = wanted.removeFirst()
        let duration = project.sourceDuration
        Task {
            if let (image, _) = try? await generator.image(at: CMTime(seconds: min(t, max(duration - 0.05, 0)), preferredTimescale: 600)) {
                thumbnails.append((t, image))
                needsDisplay = true
            }
            loading = false
            loadNext()
        }
    }

    private func nearestThumbnail(_ t: Double) -> CGImage? {
        guard !thumbnails.isEmpty else { return nil }
        return thumbnails.min { abs($0.time - t) < abs($1.time - t) }?.image
    }

    /// The source frame shown at an output time (for the zoom inspector).
    func thumbnail(at t: Double) -> CGImage? { project.locate(t).flatMap { nearestThumbnail($0.source) } }

    // MARK: Mouse

    private enum Drag {
        case scrub
        case createZoom(start: Double, id: UUID?)
        case moveZoom(id: UUID, grab: Double, original: VideoZoom)
        case resizeZoom(id: UUID, leading: Bool)
        case trim(clip: Int, leading: Bool, original: VideoClip, grabX: CGFloat)
        case cut(start: Double)
    }
    private var drag: Drag?
    private var hoverEdge: (clip: Int, leading: Bool)?
    /// The zoom a click would add where the pointer is.
    private var hoverZoom: (start: Double, end: Double)?
    /// The cut tool: where a click would split, and the stretch a drag would cut out.
    private var hoverCut: Double?
    private var cutPreview: (Double, Double)?

    private func scissorsTime(at p: CGPoint) -> Double? {
        guard state.scissors, p.y >= Metrics.clipTop - 6, p.y <= Metrics.clipTop + Metrics.clipHeight + 6 else { return nil }
        let t = time(p.x)
        return t >= 0 && t <= project.duration ? t : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self))
    }

    private func edge(at p: CGPoint) -> (clip: Int, leading: Bool)? {
        guard p.y >= Metrics.clipTop, p.y <= Metrics.clipTop + Metrics.clipHeight, !state.scissors else { return nil }
        for (i, (_, r)) in clipRects().enumerated() {
            if abs(p.x - r.minX) < 9 { return (i, true) }
            if abs(p.x - r.maxX) < 9 { return (i, false) }
        }
        return nil
    }

    private func zoomHit(_ p: CGPoint) -> (zoom: VideoZoom, edge: Bool?)? {
        guard p.y >= Metrics.zoomTop, p.y <= Metrics.zoomTop + Metrics.zoomHeight else { return nil }
        for z in project.zooms {
            let r = zoomRect(z)
            guard r.insetBy(dx: -5, dy: 0).contains(p) else { continue }
            if abs(p.x - r.minX) < 7 { return (z, true) }
            if abs(p.x - r.maxX) < 7 { return (z, false) }
            return (z, nil)
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let e = edge(at: p)
        if e?.clip != hoverEdge?.clip || e?.leading != hoverEdge?.leading { hoverEdge = e; needsDisplay = true }
        let ghost = ghostZoom(at: p)
        if ghost?.start != hoverZoom?.start || ghost?.end != hoverZoom?.end { hoverZoom = ghost; needsDisplay = true }
        let cut = scissorsTime(at: p)
        if cut != hoverCut { hoverCut = cut; needsDisplay = true }
        updateCursor(p)
        reportHover(p)
    }

    override func mouseExited(with event: NSEvent) {
        if hoverEdge != nil || hoverZoom != nil || hoverCut != nil { hoverEdge = nil; hoverZoom = nil; hoverCut = nil; needsDisplay = true }
        onHoverFrame?(nil)
    }

    /// Hovering the thumbnail strip (not while playing or on a trim edge) previews that moment above the timeline:
    /// the time, the frame, and the pointer's x and the timeline's top edge in window coordinates.
    typealias HoverFrame = (time: Double, frame: CGImage?, x: CGFloat, top: CGFloat)
    var onHoverFrame: ((HoverFrame?) -> Void)?

    private func reportHover(_ p: CGPoint) {
        let t = time(p.x)
        guard !state.isPlaying, drag == nil, !state.scissors, edge(at: p) == nil, p.y >= Metrics.clipTop, p.y <= Metrics.clipTop + Metrics.clipHeight,
              t >= 0, t <= project.duration else { onHoverFrame?(nil); return }
        let top = convert(visibleRect, to: nil).maxY
        onHoverFrame?((t, thumbnail(at: t), convert(p, to: nil).x, top))
    }

    /// Over an empty spot of the zoom track a gray "+ Zoom" block starts at the pointer and
    /// is 60% of the visible timeline long, cut off by the next zoom or the end; too short a gap shows none.
    private func ghostZoom(at p: CGPoint) -> (start: Double, end: Double)? {
        guard p.y >= Metrics.zoomTop, p.y <= Metrics.zoomTop + Metrics.zoomHeight, zoomHit(p) == nil else { return nil }
        let start = time(p.x)
        guard start >= 0, start < project.duration else { return nil }
        let length = Double((visibleWidth - Metrics.inset * 2) / pointsPerSecond) * 0.6
        let end = min(start + length, freeRange(around: start, excluding: nil).1)
        return end - start >= 0.3 ? (start, end) : nil
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func updateCursor(_ p: CGPoint) {
        if cutMarker(at: p) != nil { NSCursor.pointingHand.set() }
        else if edge(at: p) != nil || zoomHit(p)?.edge != nil { NSCursor.resizeLeftRight.set() }
        else if state.scissors { Self.scissorsCursor.set() }
        else { NSCursor.arrow.set() }
    }

    /// The cut tool's pointer: SF Symbols' scissors, blades down onto the cut line, white with a dark outline so it
    /// reads on light and dark frames. The hot spot is the middle, where the white split line runs.
    private static let scissorsCursor: NSCursor = {
        let size = CGSize(width: 24, height: 24)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return .crosshair }
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: .pi / 2)
            let s = symbol.size
            let r = CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height)
            let outline = symbol.tinted(NSColor(white: 0, alpha: 0.85))
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-0.7, -0.7), (0.7, 0.7), (-0.7, 0.7), (0.7, -0.7)] {
                outline.draw(in: r.offsetBy(dx: dx, dy: dy))
            }
            symbol.tinted(.white).draw(in: r)
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: size.width / 2, y: size.height / 2))
    }()

    override func mouseDown(with event: NSEvent) {
        onHoverFrame?(nil)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let t = min(max(time(p.x), 0), project.duration)
        // Any click on the timeline pauses playback.
        onPause?()
        if let cut = cutMarker(at: p) {
            state.selectedCut = cut.at
            state.selectedClip = nil
            state.selectedZoom = nil
            return
        }
        state.selectedCut = nil
        if let e = edge(at: p) {
            drag = .trim(clip: e.clip, leading: e.leading, original: project.clips[e.clip], grabX: p.x)
            return
        }
        if let hit = zoomHit(p) {
            state.selectedZoom = hit.zoom.id
            state.selectedClip = nil
            if let leading = hit.edge { drag = .resizeZoom(id: hit.zoom.id, leading: leading) }
            else { drag = .moveZoom(id: hit.zoom.id, grab: t, original: hit.zoom); seek(t) }
            return
        }
        if p.y >= Metrics.zoomTop, p.y <= Metrics.zoomTop + Metrics.zoomHeight, t < project.duration - 0.2 {
            hoverZoom = nil
            state.selectedClip = nil
            drag = .createZoom(start: t, id: nil)
            seek(t)
            return
        }
        if p.y >= Metrics.clipTop, p.y <= Metrics.clipTop + Metrics.clipHeight {
            if state.scissors {
                drag = .cut(start: t)
                hoverCut = t
                needsDisplay = true
            } else if let (i, _) = project.locate(t) {
                state.selectedClip = project.clips[i].id
                state.selectedZoom = nil
                seek(t)
            }
            return
        }
        state.selectedZoom = nil
        state.selectedClip = nil
        drag = .scrub
        seek(t)
    }

    var onSeek: ((Double) -> Void)?
    var onPause: (() -> Void)?

    /// Clicks and drags move the playhead, except in the cut tool: there it stays put.
    private func seek(_ t: Double) {
        guard !state.scissors else { return }
        onSeek?(t)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let t = min(max(time(p.x), 0), project.duration)
        switch drag {
        case .scrub:
            seek(t)
        case .createZoom(let start, let id):
            let range = (min(start, t), max(start, t))
            guard range.1 - range.0 > 0.15 else { return }
            let bounded = freeRange(around: start, excluding: id)
            let z0 = max(range.0, bounded.0), z1 = min(range.1, bounded.1)
            if let id, let i = project.zooms.firstIndex(where: { $0.id == id }) {
                project.zooms[i].start = z0
                project.zooms[i].end = z1
            } else if z1 - z0 > 0.15 {
                let zoom = VideoZoom(start: z0, end: z1, follow: project.isStudio)
                project.zooms.append(zoom)
                state.selectedZoom = zoom.id
                drag = .createZoom(start: start, id: zoom.id)
            }
        case .moveZoom(let id, let grab, let original):
            guard let i = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            let length = original.end - original.start
            let bounded = freeRange(around: (original.start + original.end) / 2, excluding: id)
            let start = min(max(original.start + t - grab, bounded.0), bounded.1 - length)
            project.zooms[i].start = start
            project.zooms[i].end = start + length
        case .resizeZoom(let id, let leading):
            guard let i = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            let z = project.zooms[i]
            let bounded = freeRange(around: (z.start + z.end) / 2, excluding: id)
            if leading { project.zooms[i].start = min(max(t, bounded.0), z.end - 0.3) }
            else { project.zooms[i].end = max(min(t, bounded.1), z.start + 0.3) }
        case .trim(let index, let leading, let original, let grabX):
            let delta = Double((p.x - grabX) / pointsPerSecond)
            var clip = original
            if leading {
                let floor = index > 0 ? project.clips[index - 1].end : 0
                clip.start = min(max(original.start + delta, floor), original.end - 0.2)
            } else {
                let ceiling = index < project.clips.count - 1 ? project.clips[index + 1].start : project.sourceDuration
                clip.end = max(min(original.end + delta, ceiling), original.start + 0.2)
            }
            project.clips[index] = VideoClip(id: original.id, start: clip.start, end: clip.end)
            project.clampZooms()
        case .cut(let start):
            cutPreview = (min(start, t), max(start, t))
            hoverCut = t
        case nil:
            return
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if case .createZoom(let start, let id) = drag, id == nil, let ghost = ghostZoom(at: CGPoint(x: x(start), y: p.y)) ?? hoverZoom {
            // A click adds the zoom the ghost showed.
            let zoom = VideoZoom(start: ghost.start, end: ghost.end, follow: project.isStudio)
            project.zooms.append(zoom)
            state.selectedZoom = zoom.id
        }
        if case .cut(let start) = drag {
            // A click splits; a drag cuts the stretch out (one undo step either way).
            // The playhead stays where it was (only kept inside a now shorter video).
            if let range = cutPreview, range.1 - range.0 > 0.05 {
                project.removeRange(range.0, range.1)
                if state.time > project.duration { onSeek?(project.duration) }
            } else {
                project.split(at: start)
            }
            cutPreview = nil
        }
        drag = nil
        hoverCut = scissorsTime(at: p)
        hoverZoom = ghostZoom(at: p)
        updateCursor(p)
        needsDisplay = true
    }

    /// The gap between neighbouring zooms that `t` lies in.
    private func freeRange(around t: Double, excluding id: UUID?) -> (Double, Double) {
        var lo = 0.0, hi = project.duration
        for z in project.zooms where z.id != id {
            if z.end <= t { lo = max(lo, z.end) }
            if z.start >= t { hi = min(hi, z.start) }
        }
        return (lo, hi)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Context menu and keys

    private static func followIcon(selected: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [selected ? .white : NSColor(white: 0.7, alpha: 1)]))
        return NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: "Follows the cursor")?.withSymbolConfiguration(config)
    }

    /// Right-click: Remove on a zoom; Split / Delete on a clip.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let t = min(max(time(p.x), 0), project.duration)
        let menu = NSMenu()
        if let cut = cutMarker(at: p) {
            state.selectedCut = cut.at
            state.selectedClip = nil
            state.selectedZoom = nil
            menu.addItem(ClosureMenuItem(title: "Delete Cut") { [weak self] in self?.deleteCut(cut.at) })
        } else if let hit = zoomHit(p) {
            let zoom = hit.zoom
            state.selectedZoom = zoom.id
            menu.addItem(ClosureMenuItem(title: "Duplicate") { [weak self] in self?.duplicateZoom(zoom.id) })
            let split = ClosureMenuItem(title: "Split at Playhead") { [weak self] in self?.splitZoom(zoom.id) }
            split.isEnabled = state.time > zoom.start + 0.3 && state.time < zoom.end - 0.3
            menu.addItem(split)
            let levels = NSMenuItem(title: "Zoom Level", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for scale in [1.25, 1.5, 2.0, 2.5, 3.0, 4.0] {
                let item = ClosureMenuItem(title: "\(Int(scale * 100))%") { [weak self] in
                    guard let self, let i = self.project.zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
                    self.project.zooms[i].scale = scale
                }
                item.state = abs(zoom.scale - scale) < 0.01 ? .on : .off
                sub.addItem(item)
            }
            levels.submenu = sub
            menu.addItem(levels)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Remove") { [weak self] in self?.removeZoom(zoom.id) })
            menu.addItem(ClosureMenuItem(title: "Remove All Zooms") { [weak self] in
                self?.state.selectedZoom = nil
                self?.project.zooms = []
            })
        } else if p.y >= Metrics.clipTop, p.y <= Metrics.clipTop + Metrics.clipHeight, let (i, _) = project.locate(t) {
            let id = project.clips[i].id
            state.selectedClip = id
            menu.addItem(ClosureMenuItem(title: "Split Here") { [weak self] in self?.project.split(at: t) })
            let delete = ClosureMenuItem(title: "Delete") { [weak self] in self?.project.deleteClip(id) }
            delete.isEnabled = project.clips.count > 1
            menu.addItem(delete)
        } else {
            return nil
        }
        return menu
    }

    /// A copy right after the zoom (or in the next free gap that fits it).
    private func duplicateZoom(_ id: UUID) {
        guard let zoom = project.zooms.first(where: { $0.id == id }) else { return }
        let length = zoom.end - zoom.start
        var start = zoom.end
        for other in project.zooms.sorted(by: { $0.start < $1.start }) where other.end > start && other.start < start + length {
            start = other.end
        }
        guard start + length <= project.duration + 0.001 else { NSSound.beep(); return }
        var copy = VideoZoom(start: start, end: start + length, scale: zoom.scale, center: zoom.center, follow: zoom.follow)
        copy.end = min(copy.end, project.duration)
        project.zooms.append(copy)
        state.selectedZoom = copy.id
    }

    /// Two zooms with the same settings, split at the playhead.
    private func splitZoom(_ id: UUID) {
        guard let i = project.zooms.firstIndex(where: { $0.id == id }) else { return }
        let zoom = project.zooms[i], t = state.time
        guard t > zoom.start + 0.3, t < zoom.end - 0.3 else { return }
        var edit = project.edit
        edit.zooms[i].end = t
        edit.zooms.append(VideoZoom(start: t, end: zoom.end, scale: zoom.scale, center: zoom.center, follow: zoom.follow))
        project.edit = edit
    }

    private func removeZoom(_ id: UUID) {
        if state.selectedZoom == id { state.selectedZoom = nil }
        project.zooms.removeAll { $0.id == id }
    }

    /// ⌘+ / ⌘− zoom the timeline (like the slider).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers, ["+", "=", "-"].contains(c) else {
            return super.performKeyEquivalent(with: event)
        }
        state.timelineZoom = min(max(state.timelineZoom + (c == "-" ? -0.1 : 0.1), 0), 1)
        return true
    }

    /// Removes a cut: the cut-out part comes back, or a split's two clips join again.
    private func deleteCut(_ at: Double) {
        if let selected = state.selectedCut, abs(selected - at) < 0.001 { state.selectedCut = nil }
        project.restoreCut(at: at)
    }

    /// ⌫ / ⌦ removes the selected cut, zoom or clip.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 51 || event.keyCode == 117 else { super.keyDown(with: event); return }
        if let at = state.selectedCut { deleteCut(at) }
        else if let id = state.selectedZoom { removeZoom(id) }
        else if let id = state.selectedClip { project.deleteClip(id); state.selectedClip = nil }
    }
}
