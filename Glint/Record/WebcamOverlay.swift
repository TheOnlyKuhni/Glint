import AppKit
import AVFoundation

/// The camera of the recorder: a live preview in the bottom-right corner of the
/// recording area that scales with the area (Medium = 68 + 0.1625 × the shorter side, 18pt in from the edges at
/// 600pt), in one of four sizes and shapes, mirrored by default. While the area is being picked it lives inside the
/// selector's overlay, below the panel; when recording starts it moves into its own (recorded) window at the same spot.
/// Drag it anywhere, even outside the area; it then keeps its
/// place relative to the area's corner. A click fills the area, another click brings it back.
final class WebcamOverlay {
    static let shared = WebcamOverlay()
    static let sizeTitles = ["Small", "Medium", "Large", "Huge"]
    static let shapeTitles = ["Circle", "Square", "Rectangle", "Vertical"]
    /// Small / Medium / Large / Huge relative to Medium.
    private static let sizeFactors: [CGFloat] = [0.65, 1, 1.3, 1.95]
    /// Room around the bubble for its shadow while it has its own window.
    private static let margin: CGFloat = 12

    private let queue = DispatchQueue(label: "com.philippk.glint.webcam")
    private var session: AVCaptureSession?
    private var deviceID = ""
    private let bubble = WebcamView()
    private weak var selector: RegionSelector?
    private var window: NSPanel?
    private var recording = false
    /// The recording area in global AppKit coordinates.
    private var area: CGRect = .zero
    /// Where the user dragged the bubble: its bottom-right corner relative to the area's (nil = the default spot).
    private var offset: CGVector?
    /// The bubble's frame when the current drag began.
    private var dragStart: CGRect?
    private(set) var isFullScreen = false

    private init() {
        bubble.onClick = { [weak self] in self?.toggleFullScreen() }
        bubble.onDrag = { [weak self] delta in self?.drag(by: delta) }
        bubble.onDragEnd = { [weak self] in self?.dragStart = nil }
    }

    private var isEnabled: Bool { !Defaults[Prefs.recCamera].isEmpty }
    /// The camera bubble is on screen (picking an area or recording).
    var isVisible: Bool { bubble.window?.isVisible == true }

    /// The area picker opened: the camera shows inside its overlay, below the panel.
    func attach(to selector: RegionSelector) {
        self.selector = selector
        recording = false
        isFullScreen = false
        // Every new recording starts with the camera in its default spot inside the area, and it stays hidden until
        // an area is drawn.
        offset = nil
        area = .zero
        window?.orderOut(nil)
        bubble.removeFromSuperview()
        selector.addUnderlay(bubble)
        update()
    }

    /// The recording area changed (global AppKit coordinates).
    func areaChanged(_ rect: CGRect) {
        area = rect
        layout()
    }

    /// Recording starts: the bubble moves from the overlay into its own window, which is recorded.
    func beginRecording(area: CGRect) {
        self.area = area
        recording = true
        selector = nil
        bubble.removeFromSuperview()
        guard isEnabled, session != nil else { return }
        let window = self.window ?? makeWindow()
        window.contentView?.addSubview(bubble)
        layout()
        window.orderFrontRegardless()
    }

    /// Applies the camera settings: starts, switches or stops the camera and lays the bubble out.
    func update() {
        let id = Defaults[Prefs.recCamera]
        guard !id.isEmpty else { stopSession(); layout(); return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in DispatchQueue.main.async { if granted { self.update() } } }
            return
        default:
            glintLog("camera: no access")
            return
        }
        if id != deviceID || session == nil {
            // Continuity and external cameras are only known after a discovery session has looked for them.
            guard let device = AVCaptureDevice(uniqueID: id) ?? RecordMenus.devices(.video).first(where: { $0.uniqueID == id }) else {
                glintLog("camera: device \(id) not found")
                stopSession()
                layout()
                return
            }
            start(device)
        }
        layout()
    }

    /// The recorder closed.
    func hide() {
        stopSession()
        selector = nil
        recording = false
        isFullScreen = false
        bubble.removeFromSuperview()
        window?.orderOut(nil)
    }

    func toggleFullScreen() {
        isFullScreen.toggle()
        layout()
    }

    // MARK: Camera

    private func start(_ device: AVCaptureDevice) {
        stopSession()
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            glintLog("camera: can't open \(device.localizedName)")
            return
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        session.addInput(input)
        session.commitConfiguration()
        self.session = session
        deviceID = device.uniqueID
        bubble.show(session)
        // Starting and stopping run one after another off the main thread, so a quick switch can't overlap.
        queue.async { session.startRunning() }
    }

    private func stopSession() {
        guard let session else { return }
        self.session = nil
        deviceID = ""
        bubble.show(nil)
        queue.async { session.stopRunning() }
    }

    // MARK: Layout

    private func layout() {
        let visible = isEnabled && session != nil && !area.isEmpty && (selector != nil || recording)
        bubble.isHidden = !visible
        guard visible else { if recording { window?.orderOut(nil) }; return }
        let frame = bubbleFrame()
        let shape = Defaults[Prefs.recCameraShape]
        let radius: CGFloat = isFullScreen ? 0 : shape == 0 ? min(frame.width, frame.height) / 2 : 22 * frame.height / 166
        bubble.style(radius: radius, mirrored: Defaults[Prefs.recCameraFlip])
        if let host = selector?.overlayView, let hostWindow = host.window {
            bubble.frame = host.convert(hostWindow.convertFromScreen(frame), from: nil)
        } else if let window {
            let m = Self.margin
            window.setFrame(frame.insetBy(dx: -m, dy: -m), display: true)
            bubble.frame = CGRect(x: m, y: m, width: frame.width, height: frame.height)
        }
    }

    /// Full screen fills the area (10pt in while picking, so the brackets stay visible); otherwise the bubble sits
    /// in the area's bottom-right corner or where it was dragged.
    private func bubbleFrame() -> CGRect {
        if isFullScreen { return recording ? area : area.insetBy(dx: 10, dy: 10) }
        let short = min(area.width, area.height)
        let medium = min(68.4 + 0.1625 * short, 0.8 * short)
        let s = medium * Self.sizeFactors[min(max(Defaults[Prefs.recCameraSize], 0), 3)]
        let size: CGSize = switch Defaults[Prefs.recCameraShape] {
        case 2: CGSize(width: s * 4 / 3, height: s)
        case 3: CGSize(width: s * 3 / 4, height: s)
        default: CGSize(width: s, height: s)
        }
        let gap = 6.5 + 0.018 * short
        let corner = offset ?? CGVector(dx: -gap, dy: gap)
        return CGRect(x: area.maxX + corner.dx - size.width, y: area.minY + corner.dy, width: size.width, height: size.height)
    }

    private func drag(by delta: CGVector) {
        guard !isFullScreen else { return }
        let start = dragStart ?? bubbleFrame()
        dragStart = start
        let moved = start.offsetBy(dx: delta.dx, dy: delta.dy)
        offset = CGVector(dx: moved.maxX - area.maxX, dy: moved.minY - area.minY)
        layout()
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = RecordingOverlayTitle.recorded
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the dimming, below the control bar (which may sit inside a full-screen area).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSView()
        window = panel
        return panel
    }
}

/// The bubble: the live preview clipped to its shape, a spinner until the first frames arrive, and a soft shadow.
/// Dragging moves it; a click without moving toggles full screen.
private final class WebcamView: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((CGVector) -> Void)?
    var onDragEnd: (() -> Void)?
    private let clip = NSView()
    private let preview = AVCaptureVideoPreviewLayer()
    private let spinner = NSProgressIndicator()
    private var radius: CGFloat = 0
    private var startObserver: NSObjectProtocol?
    private var down: NSPoint?
    private var moved = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        preview.videoGravity = .resizeAspectFill
        clip.layer?.addSublayer(preview)
        addSubview(clip)
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows a session's picture (nil clears it); the spinner turns until it runs.
    func show(_ session: AVCaptureSession?) {
        if let startObserver { NotificationCenter.default.removeObserver(startObserver) }
        startObserver = nil
        preview.session = session
        guard let session else { spinner.stopAnimation(nil); return }
        if session.isRunning { spinner.stopAnimation(nil); return }
        spinner.startAnimation(nil)
        startObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session,
                                                               queue: .main) { [weak self] _ in self?.spinner.stopAnimation(nil) }
    }

    func style(radius: CGFloat, mirrored: Bool) {
        self.radius = radius
        preview.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        layoutLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutLayers()
    }

    private func layoutLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clip.layer?.cornerRadius = radius
        preview.bounds = bounds
        preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
        let s = spinner.fittingSize
        spinner.frame = CGRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseDown(with event: NSEvent) {
        down = NSEvent.mouseLocation
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        let m = NSEvent.mouseLocation
        if hypot(m.x - down.x, m.y - down.y) > 3 { moved = true }
        if moved { onDrag?(CGVector(dx: m.x - down.x, dy: m.y - down.y)) }
    }

    override func mouseUp(with event: NSEvent) {
        if down != nil, !moved { onClick?() }
        if moved { onDragEnd?() }
        down = nil
    }
}
