import AppKit
import AVFoundation
import Combine

/// The timeline, top to bottom: seconds ruler with the red playhead, the camera track (Studio Mode recordings with a
/// camera), the 30pt zoom track ("+ Click or drag to add zoom"), the 60pt clip of thumbnails with its cut markers, and
/// the events (Studio Mode), 26pt in from both sides. Drag the clip's edges to trim (a "✂ 0.8s" marker shows what was
/// cut; click it to bring it back), with the scissors click to split or drag across a stretch to cut it out, click a
/// clip and press ⌫ to delete it. Zooms and camera actions: click or drag on their track to add one, drag to move,
/// drag its ends to resize, ⌫ deletes. Hovering an item tells what it is.
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
        static let cameraTop: CGFloat = 44
        static let cameraHeight: CGFloat = 28
        static let zoomTop: CGFloat = 79
        static let zoomHeight: CGFloat = 30
        static let clipTop: CGFloat = 122
        static let clipHeight: CGFloat = 60
        static let cutTop: CGFloat = 190
        /// Studio Mode's events: pointer row (clicks, drags, scrolling), then keyboard row (typing, shortcuts).
        static let pointerRow: CGFloat = 223
        static let keyRow: CGFloat = 242
        static let eventsTop: CGFloat = 214
        static let eventsBottom: CGFloat = 252
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
            state.$rawFrames.dropFirst().sink { [weak self] raw in
                DispatchQueue.main.async {
                    guard let self, raw != self.showsRawFrames else { return }
                    self.showsRawFrames = raw
                    self.thumbnails = []
                    self.reloadThumbnails()
                }
            },
            state.$selectedZoom.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } },
            state.$selectedCamera.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } },
            state.$selectedEvent.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } },
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
        showsRawFrames = state.rawFrames
        reloadThumbnails()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func refresh() {
        resize()
        needsDisplay = true
        // The hovered item may have changed (its label says what it is now).
        if let hoverPoint { updateHoverInfo(hoverPoint) }
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
            state.timelineFitZoom = state.timelineZoom
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

    // MARK: Lanes (camera actions and zooms)

    /// The tracks of stretches above the clip: camera actions (Studio Mode recordings with a camera) and zooms.
    private enum Lane { case camera, zoom }
    private struct Span: Equatable { var id: UUID; var start: Double; var end: Double }

    private var lanes: [Lane] { project.isStudio && project.hasCamera ? [.camera, .zoom] : [.zoom] }
    private func top(_ lane: Lane) -> CGFloat { lane == .camera ? Metrics.cameraTop : Metrics.zoomTop }
    private func height(_ lane: Lane) -> CGFloat { lane == .camera ? Metrics.cameraHeight : Metrics.zoomHeight }
    private func lane(at p: CGPoint) -> Lane? { lanes.first { p.y >= top($0) && p.y <= top($0) + height($0) } }

    private func spans(_ lane: Lane) -> [Span] {
        switch lane {
        case .camera: project.cameraLayouts.map { Span(id: $0.id, start: $0.start, end: $0.end) }
        case .zoom: project.zooms.map { Span(id: $0.id, start: $0.start, end: $0.end) }
        }
    }

    private func spanRect(_ lane: Lane, _ s: Span) -> CGRect {
        CGRect(x: x(s.start), y: top(lane), width: x(s.end) - x(s.start), height: height(lane))
    }

    private func setSpan(_ lane: Lane, _ id: UUID, start: Double, end: Double) {
        switch lane {
        case .camera:
            guard let i = project.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
            var layout = project.cameraLayouts[i]
            layout.start = start
            layout.end = end
            project.cameraLayouts[i] = layout
        case .zoom:
            guard let i = project.zooms.firstIndex(where: { $0.id == id }) else { return }
            var zoom = project.zooms[i]
            zoom.start = start
            zoom.end = end
            project.zooms[i] = zoom
        }
    }

    /// Adds and selects a stretch: a zoom (following the cursor in Studio Mode) or a full-size camera action (its
    /// resize settings start as the Camera section's).
    @discardableResult private func addSpan(_ lane: Lane, start: Double, end: Double) -> UUID {
        switch lane {
        case .camera:
            let c = project.edit.camera
            let layout = CameraLayout(start: start, end: end, size: c.size, shape: c.shape, position: c.position)
            project.cameraLayouts.append(layout)
            select(.camera, layout.id)
            return layout.id
        case .zoom:
            let zoom = VideoZoom(start: start, end: end, follow: project.isStudio)
            project.zooms.append(zoom)
            select(.zoom, zoom.id)
            return zoom.id
        }
    }

    private func selected(_ lane: Lane) -> UUID? { lane == .camera ? state.selectedCamera : state.selectedZoom }

    /// Selects one stretch (nil: none); clips and cut markers are deselected.
    private func select(_ lane: Lane?, _ id: UUID?) {
        state.selectedCamera = lane == .camera ? id : nil
        state.selectedZoom = lane == .zoom ? id : nil
        state.selectedClip = nil
        state.selectedCut = nil
        state.selectedEvent = nil
    }

    private func removeSpan(_ lane: Lane, _ id: UUID) {
        if selected(lane) == id { select(nil, nil) }
        switch lane {
        case .camera: project.cameraLayouts.removeAll { $0.id == id }
        case .zoom: project.zooms.removeAll { $0.id == id }
        }
    }

    /// A copy right after the stretch (or in the next free gap that fits it).
    private func duplicateSpan(_ lane: Lane, _ id: UUID) {
        guard let span = spans(lane).first(where: { $0.id == id }) else { return }
        let length = span.end - span.start
        var start = span.end
        for other in spans(lane).sorted(by: { $0.start < $1.start }) where other.end > start && other.start < start + length {
            start = other.end
        }
        guard start + length <= project.duration + 0.001 else { NSSound.beep(); return }
        let end = min(start + length, project.duration)
        switch lane {
        case .camera:
            guard var copy = project.cameraLayouts.first(where: { $0.id == id }) else { return }
            copy.id = UUID(); copy.start = start; copy.end = end
            project.cameraLayouts.append(copy)
            select(.camera, copy.id)
        case .zoom:
            guard var copy = project.zooms.first(where: { $0.id == id }) else { return }
            copy.id = UUID(); copy.start = start; copy.end = end
            project.zooms.append(copy)
            select(.zoom, copy.id)
        }
    }

    /// Two stretches with the same settings, split at the playhead (one undo step).
    private func splitSpan(_ lane: Lane, _ id: UUID) {
        let t = state.time
        var edit = project.edit
        switch lane {
        case .camera:
            guard let i = edit.cameraLayouts.firstIndex(where: { $0.id == id }) else { return }
            var copy = edit.cameraLayouts[i]
            guard t > copy.start + 0.3, t < copy.end - 0.3 else { return }
            edit.cameraLayouts[i].end = t
            copy.id = UUID(); copy.start = t
            edit.cameraLayouts.append(copy)
        case .zoom:
            guard let i = edit.zooms.firstIndex(where: { $0.id == id }) else { return }
            var copy = edit.zooms[i]
            guard t > copy.start + 0.3, t < copy.end - 0.3 else { return }
            edit.zooms[i].end = t
            copy.id = UUID(); copy.start = t
            edit.zooms.append(copy)
        }
        project.edit = edit
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
        lanes.forEach(drawLane)
        drawClips()
        drawCuts()
        drawEvents()
        drawPlayhead()
        drawScissors()
        drawHoverInfo()
        updateToolTips()
    }

    // MARK: Studio Mode events

    /// What happened while recording (Studio Mode only), in source time.
    private lazy var allEvents: [StudioEvent] = project.studio.map(StudioEvent.make) ?? []
    /// The ones not removed.
    private var events: [StudioEvent] {
        let removed = Set(project.edit.removedEvents)
        return removed.isEmpty ? allEvents : allEvents.filter { !removed.contains($0.id) }
    }

    /// An event's span on the timeline, nil if it was cut out. Points get a few points of width.
    private func eventRect(_ e: StudioEvent) -> CGRect? {
        guard let a = project.outputTime(source: e.start) else { return nil }
        let b = project.outputTime(source: e.end) ?? a
        let y = e.isKeyboard ? Metrics.keyRow : Metrics.pointerRow
        switch e.kind {
        case .click, .rightClick: return CGRect(x: x(a) - 4, y: y - 4, width: 8, height: 8)
        case .shortcut, .key:
            let w = (e.text ?? "").size(withAttributes: Self.eventFont).width + 10
            return CGRect(x: x(a) - w / 2, y: y - 7, width: w, height: 14)
        case .typing: return CGRect(x: x(a) - 3, y: y - 7, width: max(x(b) - x(a) + 6, 12), height: 14)
        case .drag, .scroll: return CGRect(x: x(a) - 3, y: y - 3, width: max(x(b) - x(a), 0) + 6, height: 6)
        }
    }

    private func studioEvent(at p: CGPoint) -> StudioEvent? {
        // Points first: they sit on top of the stretches.
        events.filter { e in eventRect(e).map { $0.insetBy(dx: -3, dy: -3).contains(p) } ?? false }
            .min { a, b in (a.end - a.start) < (b.end - b.start) }
    }

    private static let eventFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .medium)]
    private static let keyboardIcon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))?.tinted(.white)

    private func drawEvents() {
        let events = events
        guard !events.isEmpty else { return }
        let visible = visibleRect.insetBy(dx: -40, dy: 0)
        // The selected one sits on a blue outline.
        if let id = state.selectedEvent, let e = events.first(where: { $0.id == id }), let r = eventRect(e)?.insetBy(dx: -2.5, dy: -2.5) {
            Self.blue.setStroke()
            let ring = NSBezierPath(roundedRect: r, xRadius: min(r.height / 2, 6), yRadius: min(r.height / 2, 6))
            ring.lineWidth = 2
            ring.stroke()
        }
        // Stretches under points.
        for e in events where [.drag, .scroll, .typing].contains(e.kind) {
            guard let r = eventRect(e), r.intersects(visible) else { continue }
            switch e.kind {
            case .drag: NSColor(white: 1, alpha: 0.55).setFill()
            case .scroll: NSColor(displayP3Red: 0.69, green: 0.45, blue: 0.95, alpha: 0.8).setFill()
            default: NSColor(displayP3Red: 0.25, green: 0.47, blue: 0.85, alpha: 0.85).setFill()
            }
            NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            // Typing carries a keyboard where it fits; what was typed shows on hover.
            if e.kind == .typing, r.width >= 24, let keyboard = Self.keyboardIcon {
                keyboard.draw(in: CGRect(x: r.minX + 6, y: r.midY - 4.5, width: 13, height: 9))
            }
        }
        for e in events where ![.drag, .scroll, .typing].contains(e.kind) {
            guard let r = eventRect(e), r.intersects(visible) else { continue }
            switch e.kind {
            case .click:
                NSColor.white.setFill()
                NSBezierPath(ovalIn: r).fill()
            case .rightClick:
                NSColor.systemOrange.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            case .shortcut, .key:
                NSColor(white: 0.88, alpha: 1).setFill()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                let attrs = Self.eventFont.merging([.foregroundColor: NSColor.black]) { $1 }
                ((e.text ?? "") as NSString).draw(at: CGPoint(x: r.minX + 5, y: r.midY - 6.5), withAttributes: attrs)
            default: break
            }
        }
    }

    // MARK: Hover info

    /// What the item under the pointer is, shown in a dark label next to it a moment after the pointer stops there
    /// (then right away while moving on to the next item).
    private struct HoverInfo: Equatable {
        var rect: CGRect
        var title: String
        var hint: String
    }

    private var hoverInfo: HoverInfo?
    private var hoverInfoVisible = false
    private var hoverInfoWork: DispatchWorkItem?
    private var hoverX: CGFloat = 0
    private var hoverPoint: CGPoint?
    private var hoverInfoFrame: CGRect?

    private func info(at p: CGPoint) -> HoverInfo? {
        if let cut = cutMarker(at: p) {
            return HoverInfo(rect: cutRect(cut), title: cut.length > 0 ? "\(Self.cutLabel(cut.length)) cut out here" : "Clip split here",
                             hint: cut.length > 0 ? "Click to select, ⌫ puts the cut-out part back" : "Click to select, ⌫ joins the two clips again")
        }
        if let hit = spanHit(p) {
            let rect = spanRect(hit.lane, hit.span)
            let length = String(format: "%.1f s", hit.span.end - hit.span.start)
            switch hit.lane {
            case .zoom:
                guard let z = project.zooms.first(where: { $0.id == hit.span.id }) else { return nil }
                let mode = z.follow && project.isStudio ? "follows the cursor" : "fixed spot"
                return HoverInfo(rect: rect, title: "Zoom \(Int((z.scale * 100).rounded()))% · \(mode) · \(length)",
                                 hint: "Click to edit, drag to move, drag its ends to resize, ⌫ removes it")
            case .camera:
                guard let l = project.cameraLayouts.first(where: { $0.id == hit.span.id }) else { return nil }
                let what = l.kind == .bubble
                    ? "Resize to \(CameraLayout.shapeTitles[min(max(l.shape, 0), 3)].lowercased()), \(l.position.title.lowercased()), \(Int((l.size * 100).rounded()))%"
                    : l.title
                return HoverInfo(rect: rect, title: "Camera action: \(what) · \(length)",
                                 hint: "Click to edit, drag to move, drag its ends to resize, ⌫ removes it")
            }
        }
        if let e = studioEvent(at: p), let rect = eventRect(e) {
            return HoverInfo(rect: rect, title: e.title, hint: "Click to select it and jump there; ⌫ or right-click removes it")
        }
        let t = time(p.x)
        if !state.scissors, edge(at: p) == nil, p.y >= Metrics.clipTop, p.y <= Metrics.clipTop + Metrics.clipHeight,
           t >= 0, t <= project.duration, let (i, _) = project.locate(t) {
            let clip = project.clips[i]
            let count = project.clips.count
            let which = count > 1 ? "Clip \(i + 1) of \(count)" : "Clip"
            return HoverInfo(rect: clipRects()[i].1,
                             title: "\(which) · \(Self.timeLabel(clip.start))–\(Self.timeLabel(clip.end)) of the recording · " + String(format: "%.1f s", clip.duration),
                             hint: "Click to select (⌫ deletes it), drag its ends to trim, right-click to split")
        }
        return nil
    }

    /// Follows the pointer (`nil`: it left, or a click or drag started).
    private func updateHoverInfo(_ p: CGPoint?) {
        let next = p.flatMap { drag == nil ? info(at: $0) : nil }
        hoverPoint = p
        if let p { hoverX = p.x }
        if next != hoverInfo {
            hoverInfo = next
            hoverInfoWork?.cancel()
            if next == nil {
                hoverInfoVisible = false
            } else if !hoverInfoVisible {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.hoverInfoVisible = true
                    self.redrawHoverInfo()
                }
                hoverInfoWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }
        redrawHoverInfo()
    }

    private func redrawHoverInfo() {
        let frame = hoverInfoVisible ? hoverInfo.map(hoverInfoRect) : nil
        guard frame != hoverInfoFrame else { return }
        if let old = hoverInfoFrame { setNeedsDisplay(old.insetBy(dx: -2, dy: -2)) }
        if let frame { setNeedsDisplay(frame.insetBy(dx: -2, dy: -2)) }
        hoverInfoFrame = frame
    }

    private static let hoverTitleFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.white]
    private static let hoverHintFont: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor(white: 0.68, alpha: 1)]

    /// Above the item at the pointer (below it when there's no room), inside the visible part of the timeline.
    private func hoverInfoRect(_ info: HoverInfo) -> CGRect {
        let width = max((info.title as NSString).size(withAttributes: Self.hoverTitleFont).width,
                        (info.hint as NSString).size(withAttributes: Self.hoverHintFont).width) + 20
        let height: CGFloat = 36
        let visible = visibleRect
        let anchor = min(max(hoverX, info.rect.minX), info.rect.maxX)
        let x = min(max(anchor - width / 2, visible.minX + 4), visible.maxX - width - 4)
        let above = info.rect.minY - 5 - height
        let y = above >= visible.minY + 2 ? above : info.rect.maxY + 5
        return CGRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height)
    }

    private func drawHoverInfo() {
        guard hoverInfoVisible, let info = hoverInfo else { return }
        let r = hoverInfoRect(info)
        NSColor(white: 0.06, alpha: 0.94).setFill()
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        NSColor(white: 1, alpha: 0.12).setStroke()
        NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
        (info.title as NSString).draw(at: CGPoint(x: r.minX + 10, y: r.minY + 4), withAttributes: Self.hoverTitleFont)
        (info.hint as NSString).draw(at: CGPoint(x: r.minX + 10, y: r.minY + 19), withAttributes: Self.hoverHintFont)
    }

    // MARK: Hover hints

    /// Tooltips for the empty places (the ruler, a track's gaps, the events row, the clip with the cut tool); items
    /// get the hover info instead. Areas are only rebuilt when they move, otherwise redraws during playback would
    /// keep restarting the 1 s delay.
    private var toolTipRects: [CGRect] = []

    private func updateToolTips() {
        var rects = [CGRect(x: 0, y: 0, width: bounds.width, height: lanes.map(top).min()! - 4)]
        let end = x(project.duration)
        for lane in lanes {
            var gapStart = Metrics.inset
            for r in spans(lane).map({ spanRect(lane, $0) }).sorted(by: { $0.minX < $1.minX }) {
                if r.minX > gapStart { rects.append(CGRect(x: gapStart, y: top(lane), width: r.minX - gapStart, height: height(lane))) }
                gapStart = max(gapStart, r.maxX)
            }
            if end > gapStart { rects.append(CGRect(x: gapStart, y: top(lane), width: end - gapStart, height: height(lane))) }
        }
        rects += clipRects().map(\.1)
        if !allEvents.isEmpty {
            rects.append(CGRect(x: 0, y: Metrics.eventsTop, width: bounds.width, height: Metrics.eventsBottom - Metrics.eventsTop))
        }
        guard rects != toolTipRects else { return }
        toolTipRects = rects
        removeAllToolTips()
        for r in rects { addToolTip(r, owner: self, userData: nil) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if info(at: point) != nil { return "" }
        if point.y >= Metrics.eventsTop, point.y <= Metrics.eventsBottom, !allEvents.isEmpty {
            return "What happened while recording: clicks, drags and scrolling (top), typing and shortcuts (bottom). Right-click to bring back removed ones."
        }
        switch lane(at: point) {
        case .camera: return "Click to add a camera action (full size, resize or hide the camera for a while), or drag over a stretch"
        case .zoom: return "Click to add a zoom, or drag to add one over a stretch"
        case nil: break
        }
        if point.y >= Metrics.clipTop, point.y <= Metrics.clipTop + Metrics.clipHeight {
            return state.scissors ? "Click to split the clip here, drag across it to cut that part out (Esc leaves the cut tool)" : ""
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

    private func drawLane(_ lane: Lane) {
        let end = x(project.duration)
        let track = CGRect(x: Metrics.inset, y: top(lane), width: end - Metrics.inset, height: height(lane))
        let radius: CGFloat = lane == .camera ? 7 : 8
        Self.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        NSColor(white: 1, alpha: 0.04).setStroke()
        NSBezierPath(roundedRect: track.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius).stroke()
        let fontSize: CGFloat = lane == .camera ? 12 : 13
        if let ghost = hoverGhost, ghost.lane == lane, drag == nil {
            let r = CGRect(x: x(ghost.start), y: top(lane), width: x(ghost.end) - x(ghost.start), height: height(lane))
            NSColor(white: 0x33 / 255.0, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius - 1, yRadius: radius - 1).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor(white: 0.62, alpha: 1)]
            let text = (lane == .camera ? "+  Camera" : "+  Zoom") as NSString
            let size = text.size(withAttributes: attrs)
            if size.width + 12 < r.width { text.draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs) }
        } else if spans(lane).isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor(white: 0.55, alpha: 1)]
            let text = (lane == .camera ? "+  Click or drag to add a camera action" : "+  Click or drag to add zoom") as NSString
            let size = text.size(withAttributes: attrs)
            let visible = visibleRect.intersection(track)
            text.draw(at: CGPoint(x: (visible.isEmpty ? track : visible).midX - size.width / 2, y: track.midY - size.height / 2), withAttributes: attrs)
        }
        for span in spans(lane) {
            let r = spanRect(lane, span)
            let isSelected = selected(lane) == span.id
            (isSelected ? Self.blue : NSColor(white: 0x3A / 255.0, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: radius - 1, yRadius: radius - 1).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                                                        .foregroundColor: isSelected ? NSColor.white : NSColor(white: 0.7, alpha: 1)]
            // Zooms: "Zoom 150%", with a cursor before it when following the cursor. Camera: its symbol and look.
            let text: NSString
            var icon: NSImage?
            switch lane {
            case .zoom:
                guard let z = project.zooms.first(where: { $0.id == span.id }) else { continue }
                text = "Zoom \(Int((z.scale * 100).rounded()))%" as NSString
                if z.follow { icon = Self.icon("cursorarrow", selected: isSelected) }
            case .camera:
                guard let l = project.cameraLayouts.first(where: { $0.id == span.id }) else { continue }
                text = l.title as NSString
                icon = Self.icon(Self.cameraSymbol(l), selected: isSelected)
            }
            let size = text.size(withAttributes: attrs)
            let iconWidth: CGFloat = icon == nil ? 0 : 17
            if size.width + iconWidth + 12 < r.width {
                let x = r.midX - (size.width + iconWidth) / 2
                icon.map { draw($0, centeredIn: CGRect(x: x, y: r.minY, width: 13, height: r.height)) }
                text.draw(at: CGPoint(x: x + iconWidth, y: r.midY - size.height / 2), withAttributes: attrs)
            } else if let icon, r.width > 18 {
                draw(icon, centeredIn: CGRect(x: r.midX - 6.5, y: r.minY, width: 13, height: r.height))
            }
            drawGrips(lane, span.id, in: r)
        }
    }

    private func draw(_ icon: NSImage, centeredIn r: CGRect) {
        let s = icon.size
        icon.draw(in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
    }

    private static func cameraSymbol(_ l: CameraLayout) -> String {
        switch l.kind {
        case .full: "rectangle.inset.filled"
        case .hidden: "video.slash.fill"
        case .bubble: ["circle.fill", "square.fill", "rectangle.fill", "rectangle.portrait.fill"][min(max(l.shape, 0), 3)]
        }
    }

    /// While a zoom or camera action is hovered or resized: white lines just inside both ends (where it can be
    /// dragged shorter or longer); the end the pointer would grab is the bright, wider one.
    private func drawGrips(_ lane: Lane, _ id: UUID, in r: CGRect) {
        var active: Bool?
        if case .resizeSpan(let l, let spanID, let leading) = drag, l == lane, spanID == id { active = leading }
        else if drag == nil, let hover = hoverSpanEdge, hover.lane == lane, hover.id == id { active = hover.edge }
        else { return }
        guard r.width > 16 else { return }
        for leading in [true, false] {
            let grabbed = active == leading
            let w: CGFloat = grabbed ? 3 : 2
            let x = leading ? r.minX + 5 : r.maxX - 5 - w
            NSColor(white: 1, alpha: grabbed ? 1 : 0.55).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: r.minY + 6, width: w, height: r.height - 12), xRadius: w / 2, yRadius: w / 2).fill()
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

    /// The strip shows the recording's own frames (raw) or the edited video's (zooms, cursor, camera…); either way
    /// they're kept by source time.
    private var showsRawFrames = false
    private var editedSource: (asset: AVAsset, composition: AVVideoComposition)?
    /// Bumped whenever the frames are made again; older results are dropped.
    private var generation = 0
    private var batchTask: Task<Void, Never>?
    private var lookWork: DispatchWorkItem?

    /// The edited video, rendered small (from the editor; again after every change of the clips).
    func setEditedSource(asset: AVAsset, composition: AVVideoComposition) {
        editedSource = (asset, composition)
        if !showsRawFrames { reloadThumbnails() }
    }

    /// The edit's look changed: the edited frames are made again, a moment later (a slider drag doesn't restart it
    /// all the time).
    func editedLookChanged() {
        guard !showsRawFrames else { return }
        lookWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadThumbnails() }
        lookWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func makeGenerator(tolerance: CMTime) -> AVAssetImageGenerator? {
        let generator: AVAssetImageGenerator
        if showsRawFrames {
            generator = AVAssetImageGenerator(asset: project.asset)
        } else {
            guard let editedSource else { return nil }
            generator = AVAssetImageGenerator(asset: editedSource.asset)
            generator.videoComposition = editedSource.composition
        }
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 120)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    /// Where a source moment is for the generator: itself (raw), or on the edited timeline (nil: it was cut out).
    private func generatorTime(_ source: Double) -> Double? {
        if showsRawFrames { return min(source, max(project.sourceDuration - 0.05, 0)) }
        return project.outputTime(source: source).map { min($0, max(project.duration - 0.05, 0)) }
    }

    private func reloadThumbnails() {
        generation += 1
        batchTask?.cancel()
        wanted = []
        requested = []
        onDemand = nil
        let g = generation
        batchTask = Task { await makeThumbnails(generation: g) }
    }

    /// The first time tiles fill in as they come; later the old ones stay until all the new ones are there.
    private func makeThumbnails(generation g: Int) async {
        guard let generator = makeGenerator(tolerance: CMTime(value: 1, timescale: 10)) else { return }
        let duration = project.sourceDuration
        let count = max(2, min(160, Int(duration / 0.25)))
        let progressive = thumbnails.isEmpty
        var fresh: [(time: Double, image: CGImage)] = []
        for i in 0..<count {
            guard !Task.isCancelled, g == generation else { return }
            let t = duration * Double(i) / Double(count - 1)
            guard let at = generatorTime(t) else { continue }
            if let (image, _) = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)) {
                guard g == generation else { return }
                fresh.append((t, image))
                if progressive {
                    thumbnails.append((t, image))
                    if i % 8 == 0 || i == count - 1 { needsDisplay = true }
                }
            }
        }
        guard g == generation else { return }
        if !progressive {
            thumbnails = fresh
            // Close-ups made meanwhile were of the old frames: they're asked for again.
            requested = []
        }
        needsDisplay = true
    }

    private var onDemand: AVAssetImageGenerator?
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
        if onDemand == nil { onDemand = makeGenerator(tolerance: CMTime(value: 1, timescale: 60)) }
        guard let generator = onDemand else { return }
        loading = true
        let t = wanted.removeFirst()
        let g = generation
        Task {
            if let at = generatorTime(t), let (image, _) = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)), g == generation {
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
        case createSpan(lane: Lane, start: Double, id: UUID?)
        case moveSpan(lane: Lane, id: UUID, grab: Double, original: Span)
        case resizeSpan(lane: Lane, id: UUID, leading: Bool)
        case trim(clip: Int, leading: Bool, original: VideoClip, grabX: CGFloat)
        case cut(start: Double)
    }
    private var drag: Drag?
    private var hoverEdge: (clip: Int, leading: Bool)?
    /// The zoom or camera action a click would add where the pointer is.
    private var hoverGhost: (lane: Lane, start: Double, end: Double)?
    /// The zoom or camera action under the pointer and the end it would grab (its resize lines show).
    private var hoverSpanEdge: (lane: Lane, id: UUID, edge: Bool?)?
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

    /// A zoom or camera action and which end (`true` = start) the pointer grabs. The grips sit inside the ends, so
    /// where two touch, the left one's end and the right one's start are separate targets.
    private func spanHit(_ p: CGPoint) -> (lane: Lane, span: Span, edge: Bool?)? {
        guard let lane = lane(at: p) else { return nil }
        let items = spans(lane)
        for span in items {
            let r = spanRect(lane, span)
            guard p.x >= r.minX, p.x <= r.maxX else { continue }
            let grip = min(Self.grip, r.width / 3)
            if p.x - r.minX < grip { return (lane, span, true) }
            if r.maxX - p.x < grip { return (lane, span, false) }
            return (lane, span, nil)
        }
        // Just outside a free end still grabs it.
        for span in items {
            let r = spanRect(lane, span)
            if p.x < r.minX, r.minX - p.x < 5 { return (lane, span, true) }
            if p.x > r.maxX, p.x - r.maxX < 5 { return (lane, span, false) }
        }
        return nil
    }

    private static let grip: CGFloat = 10

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let e = edge(at: p)
        if e?.clip != hoverEdge?.clip || e?.leading != hoverEdge?.leading { hoverEdge = e; needsDisplay = true }
        let ghost = ghost(at: p)
        if ghost?.lane != hoverGhost?.lane || ghost?.start != hoverGhost?.start || ghost?.end != hoverGhost?.end { hoverGhost = ghost; needsDisplay = true }
        let over = spanHit(p).map { (lane: $0.lane, id: $0.span.id, edge: $0.edge) }
        if over?.lane != hoverSpanEdge?.lane || over?.id != hoverSpanEdge?.id || over?.edge != hoverSpanEdge?.edge { hoverSpanEdge = over; needsDisplay = true }
        let cut = scissorsTime(at: p)
        if cut != hoverCut { hoverCut = cut; needsDisplay = true }
        updateCursor(p)
        reportHover(p)
        updateHoverInfo(p)
    }

    override func mouseExited(with event: NSEvent) {
        if hoverEdge != nil || hoverGhost != nil || hoverCut != nil || hoverSpanEdge != nil {
            hoverEdge = nil; hoverGhost = nil; hoverCut = nil; hoverSpanEdge = nil; needsDisplay = true
        }
        onHoverFrame?(nil)
        updateHoverInfo(nil)
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

    /// Over an empty spot of the zoom or camera track a gray "+ Zoom" block starts at the pointer and is 60% of the
    /// visible timeline long, cut off by the next one or the end; too short a gap shows none.
    private func ghost(at p: CGPoint) -> (lane: Lane, start: Double, end: Double)? {
        guard let lane = lane(at: p), spanHit(p) == nil else { return nil }
        let start = time(p.x)
        guard start >= 0, start < project.duration else { return nil }
        let length = Double((visibleWidth - Metrics.inset * 2) / pointsPerSecond) * 0.6
        let end = min(start + length, freeRange(lane, around: start, excluding: nil).1)
        return end - start >= 0.3 ? (lane, start, end) : nil
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func updateCursor(_ p: CGPoint) {
        if cutMarker(at: p) != nil { NSCursor.pointingHand.set() }
        else if edge(at: p) != nil || spanHit(p)?.edge != nil { NSCursor.resizeLeftRight.set() }
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
        updateHoverInfo(nil)
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let t = min(max(time(p.x), 0), project.duration)
        // Any click on the timeline pauses playback.
        onPause?()
        if let cut = cutMarker(at: p) {
            select(nil, nil)
            state.selectedCut = cut.at
            return
        }
        state.selectedCut = nil
        if let e = edge(at: p) {
            drag = .trim(clip: e.clip, leading: e.leading, original: project.clips[e.clip], grabX: p.x)
            return
        }
        if let hit = spanHit(p) {
            select(hit.lane, hit.span.id)
            if let leading = hit.edge { drag = .resizeSpan(lane: hit.lane, id: hit.span.id, leading: leading) }
            else { drag = .moveSpan(lane: hit.lane, id: hit.span.id, grab: t, original: hit.span); seek(t) }
            return
        }
        if let lane = lane(at: p), t < project.duration - 0.2 {
            hoverGhost = nil
            select(nil, nil)
            drag = .createSpan(lane: lane, start: t, id: nil)
            seek(t)
            return
        }
        if p.y >= Metrics.clipTop, p.y <= Metrics.clipTop + Metrics.clipHeight {
            if state.scissors {
                drag = .cut(start: t)
                hoverCut = t
                needsDisplay = true
            } else if let (i, _) = project.locate(t) {
                select(nil, nil)
                state.selectedClip = project.clips[i].id
                seek(t)
            }
            return
        }
        select(nil, nil)
        // A click on an action selects it and jumps to where it starts.
        if let e = studioEvent(at: p) {
            state.selectedEvent = e.id
            if let start = project.outputTime(source: e.start) { seek(start) }
            return
        }
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
        case .createSpan(let lane, let start, let id):
            let range = (min(start, t), max(start, t))
            guard range.1 - range.0 > 0.15 else { return }
            let bounded = freeRange(lane, around: start, excluding: id)
            let a = max(range.0, bounded.0), b = min(range.1, bounded.1)
            if let id { setSpan(lane, id, start: a, end: b) }
            else if b - a > 0.15 { drag = .createSpan(lane: lane, start: start, id: addSpan(lane, start: a, end: b)) }
        case .moveSpan(let lane, let id, let grab, let original):
            let length = original.end - original.start
            let bounded = freeRange(lane, around: (original.start + original.end) / 2, excluding: id)
            let start = min(max(original.start + t - grab, bounded.0), bounded.1 - length)
            setSpan(lane, id, start: start, end: start + length)
        case .resizeSpan(let lane, let id, let leading):
            guard let span = spans(lane).first(where: { $0.id == id }) else { return }
            let bounded = freeRange(lane, around: (span.start + span.end) / 2, excluding: id)
            if leading { setSpan(lane, id, start: min(max(t, bounded.0), span.end - 0.3), end: span.end) }
            else { setSpan(lane, id, start: span.start, end: max(min(t, bounded.1), span.start + 0.3)) }
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
            project.clampToDuration()
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
        if case .createSpan(let lane, let start, let id) = drag, id == nil, let ghost = ghost(at: CGPoint(x: x(start), y: top(lane) + 1)) {
            // A click adds the zoom or camera action the ghost showed.
            addSpan(lane, start: ghost.start, end: ghost.end)
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
        hoverGhost = ghost(at: p)
        updateCursor(p)
        needsDisplay = true
    }

    /// The gap between neighbouring zooms (or camera actions) that `t` lies in.
    private func freeRange(_ lane: Lane, around t: Double, excluding id: UUID?) -> (Double, Double) {
        var lo = 0.0, hi = project.duration
        for s in spans(lane) where s.id != id {
            if s.end <= t { lo = max(lo, s.end) }
            if s.start >= t { hi = min(hi, s.start) }
        }
        return (lo, hi)
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Context menu and keys

    private static func icon(_ name: String, selected: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [selected ? .white : NSColor(white: 0.7, alpha: 1)]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// Right-click: a zoom's or camera action's options; Split / Delete on a clip; Delete Cut on a cut marker.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        let t = min(max(time(p.x), 0), project.duration)
        updateHoverInfo(nil)
        let menu = NSMenu()
        if let cut = cutMarker(at: p) {
            select(nil, nil)
            state.selectedCut = cut.at
            menu.addItem(ClosureMenuItem(title: "Delete Cut") { [weak self] in self?.deleteCut(cut.at) })
        } else if let hit = spanHit(p) {
            let lane = hit.lane, span = hit.span
            select(lane, span.id)
            if lane == .camera, let layout = project.cameraLayouts.first(where: { $0.id == span.id }) {
                for kind in CameraLayout.Kind.allCases {
                    let item = ClosureMenuItem(title: kind.title) { [weak self] in
                        guard let self, let i = self.project.cameraLayouts.firstIndex(where: { $0.id == span.id }) else { return }
                        self.project.cameraLayouts[i].kind = kind
                    }
                    item.state = layout.kind == kind ? .on : .off
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
            menu.addItem(ClosureMenuItem(title: "Duplicate") { [weak self] in self?.duplicateSpan(lane, span.id) })
            let split = ClosureMenuItem(title: "Split at Playhead") { [weak self] in self?.splitSpan(lane, span.id) }
            split.isEnabled = state.time > span.start + 0.3 && state.time < span.end - 0.3
            menu.addItem(split)
            if lane == .zoom, let zoom = project.zooms.first(where: { $0.id == span.id }) {
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
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Remove") { [weak self] in self?.removeSpan(lane, span.id) })
            menu.addItem(ClosureMenuItem(title: lane == .zoom ? "Remove All Zooms" : "Remove All Camera Actions") { [weak self] in
                guard let self else { return }
                self.select(nil, nil)
                if lane == .zoom { self.project.zooms = [] } else { self.project.cameraLayouts = [] }
            })
            if lane == .zoom, project.isStudio { menu.addItem(redoZoomsItem()) }
        } else if lane(at: p) == .zoom, project.isStudio {
            menu.addItem(redoZoomsItem())
        } else if let e = studioEvent(at: p) {
            select(nil, nil)
            state.selectedEvent = e.id
            menu.addItem(ClosureMenuItem(title: "Remove \(e.kind == .typing ? "Typing" : e.title)") { [weak self] in self?.removeEvent(e.id) })
            // A shortcut or key can be hidden everywhere in this video.
            if e.kind == .shortcut || e.kind == .key,
               let key = project.studio?.keys.first(where: { abs($0.t - e.start) < 0.0005 }) {
                let excluded = ExcludedKey(code: key.code, flags: key.flags, chars: key.chars)
                let item = ClosureMenuItem(title: "Never Show “\(excluded.label)” in This Video") { [weak self] in
                    guard let self, !self.project.edit.keystrokes.excluded.contains(excluded) else { return }
                    self.project.edit.keystrokes.excluded.append(excluded)
                }
                item.isEnabled = !project.edit.keystrokes.excluded.contains(excluded)
                menu.addItem(item)
            }
            addRestoreItem(to: menu)
        } else if p.y >= Metrics.eventsTop, p.y <= Metrics.eventsBottom, !allEvents.isEmpty {
            guard !project.edit.removedEvents.isEmpty else { return nil }
            addRestoreItem(to: menu, separated: false)
        } else if p.y >= Metrics.clipTop, p.y <= Metrics.clipTop + Metrics.clipHeight, let (i, _) = project.locate(t) {
            let id = project.clips[i].id
            select(nil, nil)
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

    /// ⌘+ / ⌘− zoom the timeline (like the slider).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let c = event.charactersIgnoringModifiers, ["+", "=", "-"].contains(c) else {
            return super.performKeyEquivalent(with: event)
        }
        state.timelineZoom = min(max(state.timelineZoom + (c == "-" ? -0.1 : 0.1), 0), 1)
        return true
    }

    /// Removes an action from the events track: its click effect or keystrokes no longer show in the video.
    private func removeEvent(_ id: String) {
        if state.selectedEvent == id { state.selectedEvent = nil }
        project.edit.removedEvents.append(id)
    }

    private func addRestoreItem(to menu: NSMenu, separated: Bool = true) {
        let count = project.edit.removedEvents.count
        guard count > 0 else { return }
        if separated { menu.addItem(.separator()) }
        menu.addItem(ClosureMenuItem(title: "Bring Back Removed Actions (\(count))") { [weak self] in self?.project.edit.removedEvents = [] })
    }

    /// Studio Mode: the zooms made again from the clicks and typing, with Settings → Studio Mode's zoom options.
    private func redoZoomsItem() -> NSMenuItem {
        ClosureMenuItem(title: "Redo Automatic Zooms") { [weak self] in
            self?.select(nil, nil)
            self?.project.redoAutomaticZooms()
        }
    }

    /// Removes a cut: the cut-out part comes back, or a split's two clips join again.
    private func deleteCut(_ at: Double) {
        if let selected = state.selectedCut, abs(selected - at) < 0.001 { state.selectedCut = nil }
        project.restoreCut(at: at)
    }

    /// ⌫ / ⌦ removes the selected cut, action, camera action, zoom or clip.
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 51 || event.keyCode == 117 else { super.keyDown(with: event); return }
        if let at = state.selectedCut { deleteCut(at) }
        else if let id = state.selectedEvent { removeEvent(id) }
        else if let id = state.selectedCamera { removeSpan(.camera, id) }
        else if let id = state.selectedZoom { removeSpan(.zoom, id) }
        else if let id = state.selectedClip { project.deleteClip(id); state.selectedClip = nil }
    }
}
