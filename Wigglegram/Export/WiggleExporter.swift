import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a list of prerendered CGImages to an MP4 (AVAssetWriter) or
/// animated GIF (ImageIO). Rendering happens in `FrameBaker`; this type
/// is pure Foundation / AVFoundation.
///
/// Expands the frames into a ping-pong sequence first so the exported
/// file matches what the user sees in the preview.
enum WiggleExporter {
    enum Format {
        case mp4
        case gif
    }

    enum ExportError: LocalizedError {
        case noFrames
        case writerSetupFailed(String)
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "Nothing to export — bake some frames first."
            case .writerSetupFailed(let m): return "Export setup failed: \(m)"
            case .writerFailed(let m): return "Export failed: \(m)"
            }
        }
    }

    /// - Parameters:
    ///   - frames: the baked unique frames (no ping-pong expansion yet).
    ///   - fps: playback rate for the exported file.
    ///   - format: MP4 or GIF.
    ///   - url: output location; any existing file is overwritten.
    ///   - progress: 0..1 write progress callback on the main actor.
    @MainActor
    static func export(
        frames: [CGImage],
        fps: Int,
        format: Format,
        to url: URL,
        progress: (@MainActor (Double) -> Void)? = nil
    ) async throws {
        guard !frames.isEmpty else { throw ExportError.noFrames }

        let sequence = expandPingPong(frames)
        let width = frames[0].width
        let height = frames[0].height

        switch format {
        case .mp4:
            try await writeMP4(
                frames: sequence, fps: fps,
                size: (width, height), to: url,
                progress: progress
            )
        case .gif:
            try writeGIF(frames: sequence, fps: fps, to: url)
            progress?(1.0)
        }
    }

    /// 0,1,…,N-1,N-2,…,1 — one period of the preview playback.
    static func expandPingPong(_ frames: [CGImage]) -> [CGImage] {
        guard frames.count > 1 else { return frames }
        var out = frames
        if frames.count >= 3 {
            out.append(contentsOf: frames[1..<(frames.count - 1)].reversed())
        }
        return out
    }

    // MARK: - MP4

    private static func writeMP4(
        frames: [CGImage],
        fps: Int,
        size: (Int, Int),
        to url: URL,
        progress: (@MainActor (Double) -> Void)?
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

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        var pts = CMTime.zero

        for (i, cg) in frames.enumerated() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            guard let buf = pixelBuffer(from: cg, width: size.0, height: size.1) else {
                throw ExportError.writerFailed("pixelBuffer conversion failed")
            }
            adaptor.append(buf, withPresentationTime: pts)
            pts = CMTimeAdd(pts, frameDuration)
            await progress?(Double(i + 1) / Double(frames.count))
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
