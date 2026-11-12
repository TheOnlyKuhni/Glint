import AppKit
import Quartz

/// Shows one file in the Quick Look panel (recording previews).
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    private static let shared = QuickLook()
    private var url: URL?

    static func show(_ url: URL) {
        shared.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.bringToFront()
        panel.dataSource = shared
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}
