import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, quickAccess, wallpaper, screenshots, recording, annotate, advanced, about
    var id: String { rawValue }

    static let sidebar: [SettingsPane] = [.general, .shortcuts, .quickAccess, .wallpaper, .screenshots, .recording, .annotate, .advanced]

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .quickAccess: "Quick Access"
        case .wallpaper: "Wallpaper"
        case .screenshots: "Screenshots"
        case .recording: "Screen Recording"
        case .annotate: "Annotate"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var glyph: SettingsGlyph {
        switch self {
        case .general: .symbol("gearshape.fill", size: 15.5)
        case .shortcuts: .symbol("command", size: 14, weight: .bold)
        case .quickAccess: .symbol("rectangle.stack.fill", size: 13)
        case .wallpaper: .symbol("photo.fill.on.rectangle.fill", size: 11.5)
        case .screenshots: .symbol("camera.fill", size: 14)
        case .recording: .symbol("video.fill", size: 14)
        case .annotate: .symbol("highlighter", size: 14)
        case .advanced: .symbol("wrench.and.screwdriver.fill", size: 12.5)
        case .about: .symbol("info.circle.fill", size: 16)
        }
    }

    /// Tile gradient (top, bottom) as Display P3 values.
    var gradient: (top: UInt32, bottom: UInt32) {
        switch self {
        case .general, .shortcuts, .about: (0x868686, 0x5C5C5C)
        case .quickAccess: (0x4DA676, 0x377C50)
        case .wallpaper: (0x7CCADB, 0x63B2CC)
        case .screenshots: (0x4594F7, 0x2E64F5)
        case .recording: (0xC94662, 0xB83846)
        case .annotate: (0xE59C40, 0xDC7232)
        case .advanced: (0x8048C8, 0x5731B0)
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .quickAccess: QuickAccessSettingsView()
        case .wallpaper: WallpaperSettingsView()
        case .screenshots: ScreenshotsSettingsView()
        case .recording: RecordingSettingsView()
        case .annotate: AnnotateSettingsView()
        case .advanced: AdvancedSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

@Observable
final class SettingsModel {
    var selection: SettingsPane = .general
    var shortcutSearch = ""
}

/// System Settings–style window: AppKit split view with a fixed 220pt sidebar and SwiftUI content.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    static let shared = SettingsWindowController()
    private let model = SettingsModel()
    private let searchItemID = NSToolbarItem.Identifier("search")

    private init() {
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SettingsSidebar(model: model)))
        sidebar.minimumThickness = 220
        sidebar.maximumThickness = 220
        sidebar.canCollapse = false
        sidebar.allowsFullHeightLayout = true
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: NSHostingController(rootView: SettingsDetail(model: model))))

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 810, height: 660))
        window.center()
        window.setFrameAutosaveName("GlintSettings")
        super.init(window: window)

        let toolbar = NSToolbar(identifier: "GlintSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        observeSelection()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(pane: SettingsPane? = nil) {
        if let pane { model.selection = pane }
        NSApp.activate()
        // Glint is a menu bar app: bring the window in front of other apps' windows, on the current Space.
        window?.collectionBehavior.insert(.moveToActiveSpace)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func observeSelection() {
        withObservationTracking { _ = model.selection } onChange: { [weak self] in
            DispatchQueue.main.async { self?.selectionChanged(); self?.observeSelection() }
        }
        selectionChanged()
    }

    private func selectionChanged() {
        window?.title = model.selection.title
        guard let toolbar = window?.toolbar else { return }
        let hasSearch = toolbar.items.contains { $0.itemIdentifier == searchItemID }
        if model.selection == .shortcuts, !hasSearch {
            toolbar.insertItem(withItemIdentifier: searchItemID, at: toolbar.items.count)
        } else if model.selection != .shortcuts, let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == searchItemID }) {
            toolbar.removeItem(at: index)
            model.shortcutSearch = ""
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator, .flexibleSpace] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator, .flexibleSpace, searchItemID] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == searchItemID else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: id)
        item.searchField.placeholderString = "Search shortcuts"
        item.searchField.delegate = self
        item.preferredWidthForSearchField = 380
        return item
    }

    func controlTextDidChange(_ note: Notification) {
        if let field = note.object as? NSSearchField { model.shortcutSearch = field.stringValue }
    }
}

private struct SettingsSidebar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        List(selection: $model.selection) {
            AppBadgeRow()
                .padding(.bottom, 10)
                .selectionDisabled()
            ForEach(SettingsPane.sidebar) { pane in
                SidebarRow(pane: pane).tag(pane)
            }
        }
        .listStyle(.sidebar)
        .focusable(false)
        .safeAreaInset(edge: .bottom) {
            Button { model.selection = .about } label: {
                SidebarRow(pane: .about)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(model.selection == .about ? Color.primary.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }
}

private struct SettingsDetail: View {
    @Bindable var model: SettingsModel

    var body: some View {
        model.selection.content
            .environment(model)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    var body: some View {
        Label {
            Text(pane.title)
        } icon: {
            SettingsIcon(pane: pane)
        }
        .padding(.vertical, 4)
    }
}

enum SettingsGlyph {
    case symbol(String, size: CGFloat, weight: Font.Weight = .regular, hierarchical: Bool = false)
}

/// 24pt gradient tile with a white glyph, matching the sidebar icons.
/// Rendered to a bitmap so the sidebar's vibrancy doesn't wash out the colors.
struct SettingsIcon: View {
    let pane: SettingsPane
    private static var cache: [SettingsPane: NSImage] = [:]

    var body: some View {
        NonVibrantImage(image: Self.image(for: pane)).frame(width: 24, height: 24)
    }

    private static func image(for pane: SettingsPane) -> NSImage {
        if let cached = cache[pane] { return cached }
        let renderer = ImageRenderer(content: SettingsIconTile(pane: pane))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        cache[pane] = image
        return image
    }
}

/// Image view that opts out of the sidebar's vibrancy (which would otherwise lighten the colors).
private struct NonVibrantImage: NSViewRepresentable {
    let image: NSImage

    final class View: NSImageView {
        override var allowsVibrancy: Bool { false }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ view: View, context: Context) { view.image = image }
}

private struct SettingsIconTile: View {
    let pane: SettingsPane

    var body: some View {
        let colors = pane.gradient
        let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            tile.fill(LinearGradient(colors: [Color(hex: colors.top), Color(hex: colors.bottom)], startPoint: .top, endPoint: .bottom))
            tile.strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 0.5)
            glyph(tint: Color(hex: colors.bottom))
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private func glyph(tint: Color) -> some View {
        switch pane.glyph {
        case let .symbol(name, size, weight, hierarchical):
            Image(systemName: name)
                .font(.system(size: size, weight: weight))
                .symbolRenderingMode(hierarchical ? .hierarchical : .monochrome)
                .foregroundStyle(.white)
        }
    }
}

extension Color {
    /// Display P3 color from a hex value.
    init(hex: UInt32) {
        self.init(.displayP3, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

private struct AppBadgeRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("Glint").font(.system(size: 14, weight: .semibold))
                Text("Version \(Bundle.main.shortVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}
