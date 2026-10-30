import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// One finished capture. The file always exists in the history folder; "Save" copies it to the export location.
final class CaptureItem: Identifiable {
    let id = UUID()
    let image: CGImage
    /// Pixels per point of the source display (2 on Retina).
    let scale: CGFloat
    let date: Date
    let fileURL: URL
    let kind: CaptureKind
    /// For (non-full-screen) window captures: the raw window with transparency and shadow, so the editor can put it
    /// back on the wallpaper with adjustable padding.
    var windowImage: CGImage?
    var windowOnWallpaper = false
    /// Wallpaper around `windowImage` in the delivered picture (points), so the editor opens it the same way.
    var windowPadding: CGFloat = 0
    /// Where it was captured (AppKit screen coordinates), so a pin can appear right there.
    var screenRect: CGRect?
    /// Recordings: length in seconds (`image` is the first frame, `fileURL` the movie or GIF).
    var duration: Double?

    var isRecording: Bool { kind == .recording }
    var isGIF: Bool { fileURL.pathExtension.lowercased() == "gif" }
    var fileSize: Int64 { Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    init(image: CGImage, scale: CGFloat, date: Date, fileURL: URL, kind: CaptureKind) {
        self.image = image
        self.scale = scale
        self.date = date
        self.fileURL = fileURL
        self.kind = kind
    }

    /// An image, GIF or movie file as a capture (scale from its DPI, date from the file).
    static func load(_ url: URL, date: Date? = nil) -> CaptureItem? {
        if ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "gif" {
            return loadRecording(url, date: date)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let created = date ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return CaptureItem(image: image, scale: max(1, CGFloat(dpi / 72).rounded()), date: created, fileURL: url, kind: .screenshot)
    }
}

enum ImageEncoder {
    static func data(for image: CGImage, format: ImageFormat, scale: CGFloat) -> Data? {
        let type: UTType = switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

enum ImageProcessing {
    /// Crops away fully transparent borders (alpha ≤ 2), e.g. around a window captured with its shadow.
    static func croppedToVisible(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self)
        var minX = w, minY = h, maxX = -1, maxY = -1
        // The context's memory is top-down, like CGImage cropping coordinates.
        for y in 0..<h {
            for x in 0..<w where p[(y * w + x) * 4 + 3] > 2 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }

    /// Applies the Screenshots settings (1x scaling, sRGB, 1px border).
    static func applyOutputSettings(_ image: CGImage, scale: inout CGFloat) -> CGImage {
        var result = image
        if Defaults[Prefs.scaleRetinaTo1x], scale > 1 {
            result = resized(result, to: CGSize(width: CGFloat(result.width) / scale, height: CGFloat(result.height) / scale)) ?? result
            scale = 1
        }
        if Defaults[Prefs.convertToSRGB], let srgb = CGColorSpace(name: CGColorSpace.sRGB) {
            result = result.copy(colorSpace: srgb) ?? redraw(result, colorSpace: srgb) ?? result
        }
        if Defaults[Prefs.addBorder] {
            result = bordered(result) ?? result
        }
        return result
    }

    static func resized(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard let ctx = context(width: w, height: h, colorSpace: image.colorSpace) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func redraw(_ image: CGImage, colorSpace: CGColorSpace) -> CGImage? {
        guard let ctx = context(width: image.width, height: image.height, colorSpace: colorSpace) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    static func bordered(_ image: CGImage) -> CGImage? {
        guard let ctx = context(width: image.width, height: image.height, colorSpace: image.colorSpace) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.draw(image, in: rect)
        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.6).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        return ctx.makeImage()
    }

    static func context(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

extension CaptureItem {
    /// A movie or GIF: its first frame as the image, plus the duration.
    static func loadRecording(_ url: URL, date: Date? = nil) -> CaptureItem? {
        let created = date ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        var poster: CGImage?
        var duration: Double = 0
        if url.pathExtension.lowercased() == "gif" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            poster = CGImageSourceCreateImageAtIndex(source, 0, nil)
            for i in 0..<CGImageSourceGetCount(source) {
                let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                duration += (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
        } else {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            poster = try? generator.copyCGImage(at: .zero, actualTime: nil)
            duration = asset.duration.seconds
        }
        guard let poster else { return nil }
        let item = CaptureItem(image: poster, scale: 1, date: created, fileURL: url, kind: .recording)
        item.duration = duration.isFinite ? duration : nil
        return item
    }
}
