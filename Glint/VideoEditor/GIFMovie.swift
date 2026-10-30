import AVFoundation
import ImageIO

/// The GIF editor: a GIF is turned into a temporary H.264 movie (frames at their own delays) so the video editor
/// can edit it; saving or exporting turns the result back into a GIF with `GIFEncoder`.
enum GIFMovie {
    static func movie(from gif: URL) async -> URL? {
        await Task.detached { convert(gif) }.value
    }

    private nonisolated static func convert(_ gif: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(gif as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = first.width / 2 * 2, h = first.height / 2 * 2
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-gif-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(w * h * 8, 2_000_000)],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        var time = 0.0
        let count = CGImageSourceGetCount(source)
        for i in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil), let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600))
            time += delay(source, i)
        }
        // The last frame lasts its own delay.
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed ? url : nil
    }

    private nonisolated static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}
