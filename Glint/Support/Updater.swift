import AppKit
import Sparkle

/// Updates through Sparkle (feed: `SUFeedURL` in Info.plist). The updater only runs when the build carries a public
/// EdDSA key (`SUPublicEDKey`), so builds made from source without a key never check for or install updates.
final class Updater {
    static let shared = Updater()

    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController

    private init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = !key.trimmingCharacters(in: .whitespaces).isEmpty
        controller = SPUStandardUpdaterController(startingUpdater: isConfigured, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Updates aren't set up for this build"
            alert.informativeText = "This copy of Glint was built without an update key. Download new versions from GitHub."
            NSApp.bringToFront()
            alert.runModal()
            return
        }
        NSApp.bringToFront()
        controller.checkForUpdates(nil)
    }
}
