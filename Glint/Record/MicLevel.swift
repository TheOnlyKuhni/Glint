import AVFoundation
import Combine

/// The selected microphone's input level (0…1), for the meter: the mic cell in the recording panel and the
/// stop button while recording fill from the bottom up to the level. Runs its own small capture session (macOS lets
/// several clients read a microphone), sampled 10× a second.
final class MicLevel: ObservableObject {
    static let shared = MicLevel()

    @Published private(set) var level: Double = 0
    private let queue = DispatchQueue(label: "com.philippk.glint.miclevel")
    private var session: AVCaptureSession?
    private var deviceID = ""
    private var timer: Timer?
    private var users = 0

    /// The recorder panel or a recording needs the meter; balanced by `release()`.
    func retain() {
        users += 1
        update()
    }

    func release() {
        users = max(users - 1, 0)
        if users == 0 { stop() }
    }

    /// Follows the microphone setting (called when it changes).
    func update() {
        let id = Defaults[Prefs.recMicDevice]
        guard users > 0, !id.isEmpty, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { stop(); return }
        guard id != deviceID || session == nil else { return }
        stop()
        guard let device = RecordMenus.devices(.audio).first(where: { $0.uniqueID == id }) ?? AVCaptureDevice(uniqueID: id),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(Sink.shared, queue: queue)
        self.session = session
        deviceID = id
        queue.async { session.startRunning() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak output] _ in
            MainActor.assumeIsolated {
                guard let self, let output else { return }
                let channels = output.connections.first?.audioChannels ?? []
                guard !channels.isEmpty else { return }
                let db = channels.map { Double($0.averagePowerLevel) }.max() ?? -160
                // -50 dB (quiet room) … 0 dB (shouting) → 0…1.
                self.level = min(max((db + 50) / 50, 0), 1)
            }
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let session { queue.async { session.stopRunning() } }
        session = nil
        deviceID = ""
        level = 0
    }

    /// The data output only measures levels while it has a delegate; the samples themselves aren't needed.
    private final class Sink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        static let shared = Sink()
    }
}
