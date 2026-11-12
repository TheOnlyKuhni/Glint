import AppKit

extension NSApplication {
    /// Brings Glint in front of the app the user is in. `activate()` alone is only a request on macOS 14 and later,
    /// and macOS often turns it down for a menu bar app (no Dock icon, started from a shortcut or a panel), so
    /// Glint's windows opened behind the other app's. Every Glint window is opened by something the user just did,
    /// so taking the front is what they expect.
    func bringToFront() {
        activate(ignoringOtherApps: true)
    }
}
