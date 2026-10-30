import AppKit

/// Glyphs for the Crop / Add screenshot / Background toolbar buttons: SF Symbols as template images.
enum ModeGlyph {
    case crop, addImage, background

    var image: NSImage { Self.images[symbol] ?? NSImage() }

    private var symbol: String {
        switch self {
        case .crop: "crop"
        case .addImage: "photo.badge.plus"
        case .background: "photo.artframe"
        }
    }

    private static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues: ["crop", "photo.badge.plus", "photo.artframe"].map { name in
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium)) ?? NSImage()
        image.isTemplate = true
        return (name, image)
    })
}
