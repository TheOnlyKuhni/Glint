import AppKit
import CryptoKit

/// A re-editable save from Annotate: the unedited screenshot and its objects are kept beside the rendered file, so
/// reopening that file edits the annotations again instead of the flattened pixels (like the video editor's
/// `SavedEdit`). Stored in `Application Support/Glint/Edits/<hash of the file path>/` so export folders stay clean.
struct ImageEdit: Codable {
    var annotations: [Annotation]
    var background: BackgroundStyle?
    var counter: CounterSettings
    var scale: CGFloat
    var isWindowCapture: Bool
    /// Size of the rendered file when it was saved; a different size means another app replaced it.
    var fileSize: Int64
    /// Keys of added images (stored as `image-<key>.png` beside the original).
    var imageKeys: [String]?

    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glint/Edits", isDirectory: true)
    }()

    private static func folder(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return root.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined().prefix(32).description, isDirectory: true)
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
    }

    /// Remembers how `url` (already written) was made.
    static func store(_ doc: AnnotationDocument, for url: URL) {
        let dir = folder(for: url)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let edit = ImageEdit(annotations: doc.annotations, background: doc.background, counter: doc.counter, scale: doc.scale,
                             isWindowCapture: doc.isWindowCapture, fileSize: size(of: url), imageKeys: usedImageKeys(doc))
        for key in edit.imageKeys ?? [] {
            guard let image = doc.images[key], let data = ImageEncoder.data(for: image, format: .png, scale: 1) else { continue }
            try? data.write(to: dir.appendingPathComponent("image-\(key).png"))
        }
        guard let original = ImageEncoder.data(for: doc.baseImage, format: .png, scale: doc.scale),
              (try? original.write(to: dir.appendingPathComponent("original.png"))) != nil,
              let json = try? JSONEncoder().encode(edit) else { return }
        try? json.write(to: dir.appendingPathComponent("edit.json"))
    }

    private static func usedImageKeys(_ doc: AnnotationDocument) -> [String] {
        doc.annotations.compactMap { a in if case .image(let key) = a.kind { key } else { nil } }
    }

    /// The added images of a saved edit.
    static func images(for url: URL, edit: ImageEdit) -> [String: CGImage] {
        let dir = folder(for: url)
        var result: [String: CGImage] = [:]
        for key in edit.imageKeys ?? [] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("image-\(key).png")),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            result[key] = image
        }
        return result
    }

    /// The saved edit and original for `url`, if the file is still the one Glint wrote.
    static func load(for url: URL) -> (edit: ImageEdit, original: CGImage)? {
        let dir = folder(for: url)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("edit.json")),
              let edit = try? JSONDecoder().decode(ImageEdit.self, from: data), edit.fileSize == size(of: url),
              let imageData = try? Data(contentsOf: dir.appendingPathComponent("original.png")),
              let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (edit, image)
    }
}
