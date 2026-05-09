import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Render every wiggle frame to an offscreen texture and write them to
/// disk as an MP4 (AVAssetWriter) or animated GIF (ImageIO). All GPU
/// work happens on the viewer's coordinator; the writer side is pure
/// Foundation / AVFoundation.
enum WiggleExporter {
    enum Format {
        case mp4
        case gif
    }

    struct Config {
        var width: Int = 1024
        var height: Int = 1024
        var format: Format = .mp4
    }

    @MainActor
    static func export(
        settings: WiggleSettings,
        base: CameraPose,
        coordinator: SplatViewer.Coordinator,
        to url: URL,
        config: Config,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        let frames = max(2, settings.frameCount)
        var cgFrames: [CGImage] = []
        cgFrames.reserveCapacity(frames)

        for i in 0..<frames {
            let t = Float(i) / Float(frames)
            let pose = settings.pose(at: t, base: base)
            guard let cg = await coordinator.renderOffscreen(
                camera: pose, width: config.width, height: config.height
            ) else {
                throw ExportError.renderFailed(frameIndex: i)
            }
            cgFrames.append(cg)
            progress?(Double(i + 1) / Double(frames))
        }

        switch config.format {
        case .mp4:
            try await writeMP4(frames: cgFrames, fps: settings.fps, size: (config.width, config.height), to: url)
        case .gif:
            try writeGIF(frames: cgFrames, fps: settings.fps, to: url)
        }
    }

    enum ExportError: LocalizedError {
        case renderFailed(frameIndex: Int)
        case writerSetupFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .renderFailed(let i): return "Frame \(i) failed to render."
            case .writerSetupFailed(let m): return "Export setup failed: \(m)"
            case .writerFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    // MARK: - MP4

    private static func writeMP4(
        frames: [CGImage],
        fps: Int,
        size: (Int, Int),
        to url: URL
    ) async throws {
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ExportError.writerSetupFailed(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.0,
            AVVideoHeightKey: size.1,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.0,
            kCVPixelBufferHeightKey as String: size.1,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: attrs
        )
        guard writer.canAdd(input) else {
            throw ExportError.writerSetupFailed("writer cannot accept input")
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var pts = CMTime.zero

        for cg in frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000) // polled below via usleep
            }
            guard let buf = pixelBuffer(from: cg, width: size.0, height: size.1) else {
                throw ExportError.writerFailed("pixelBuffer conversion failed")
            }
            while !adaptor.assetWriterInput.isReadyForMoreMediaData {
                usleep(1000)
            }
            adaptor.append(buf, withPresentationTime: pts)
            pts = CMTimeAdd(pts, frameDuration)
        }

        input.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error { throw ExportError.writerFailed(err.localizedDescription) }
    }

    private static func pixelBuffer(from cg: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var buf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buf
        )
        guard status == kCVReturnSuccess, let buf else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: base, width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buf
    }

    // MARK: - GIF

    private static func writeGIF(frames: [CGImage], fps: Int, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
        ) else {
            throw ExportError.writerSetupFailed("CGImageDestinationCreate failed")
        }

        let fileProps: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0,
            ]
        ]
        CGImageDestinationSetProperties(dst, fileProps as CFDictionary)

        let delay = 1.0 / Double(max(1, fps))
        let frameProps: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFUnclampedDelayTime as String: delay,
                kCGImagePropertyGIFDelayTime as String: delay,
            ]
        ]
        for cg in frames {
            CGImageDestinationAddImage(dst, cg, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else {
            throw ExportError.writerFailed("GIF finalize failed")
        }
    }
}
