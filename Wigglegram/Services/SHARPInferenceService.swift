import Foundation
import CoreML
import CoreImage
import AppKit
import simd

/// Wraps Apple's SHARP monocular-to-3DGS CoreML model.
///
/// Ported from the sibling SharpSplat project. Differences:
/// - single-image API only (no per-project batch / disk cache),
/// - resolves `sharp.mlpackage` from the app bundle first, then falls
///   back to `~/Library/Application Support/Wigglegram/models/`.
@Observable
nonisolated final class SHARPInferenceService: @unchecked Sendable {
    private var model: MLModel?
    private var _modelSourceURL: URL?
    private let lock = NSLock()

    /// Fixed input size SHARP was exported with (don't change).
    static let modelInputSize = 1536

    var isModelLoaded: Bool { lock.withLock { model != nil } }

    /// Path to the source bundle/file that the currently-loaded model
    /// was compiled from. `nil` when no model is loaded. Used by the
    /// settings panel to show where the active model lives.
    var currentModelURL: URL? { lock.withLock { _modelSourceURL } }

    enum Error: LocalizedError {
        case modelNotFound(String)
        case modelNotLoaded
        case imageLoadFailed(String)
        case outputExtractionFailed([String])
        case invalidModelFile(String)

        var errorDescription: String? {
            switch self {
            case .modelNotFound(let m): return m
            case .modelNotLoaded: return "SHARP model has not been loaded."
            case .imageLoadFailed(let m): return "Image load failed: \(m)"
            case .outputExtractionFailed(let names):
                return "Could not extract SHARP outputs. Available: \(names.joined(separator: ", "))"
            case .invalidModelFile(let m): return m
            }
        }
    }

    // MARK: - Loading

    func loadModel() async throws {
        let modelURL = try resolveModelURL()
        let config = MLModelConfiguration()
        config.computeUnits = .all

        let compiledURL = try await compileModelIfNeeded(at: modelURL)
        let loaded = try await Task.detached(priority: .userInitiated) {
            try MLModel(contentsOf: compiledURL, configuration: config)
        }.value

        lock.withLock {
            model = loaded
            _modelSourceURL = modelURL
        }
    }

    /// Drop the currently-loaded model. Next `loadModel` call rebuilds
    /// from whatever `resolveModelURL()` currently points at. Safe to
    /// call while no model is loaded.
    func unloadModel() {
        lock.withLock {
            model = nil
            _modelSourceURL = nil
        }
    }

    /// Install a user-supplied model bundle into Application Support so
    /// subsequent launches (and `loadModel` calls) pick it up.
    ///
    /// Accepts `.mlpackage` or `.mlmodelc` bundles (directories) or
    /// a `.mlmodel` file. Copies the bundle atomically into
    /// `~/Library/Application Support/Wigglegram/models/sharp.<ext>`,
    /// replacing any existing install, and invalidates the compiled
    /// cache so the new bundle gets recompiled on next load.
    ///
    /// Returns the on-disk URL of the installed bundle. Caller is
    /// expected to follow up with `loadModel()` (typically via
    /// `AppState.installSHARPModel`).
    func installModel(from sourceURL: URL) async throws -> URL {
        let ext = sourceURL.pathExtension.lowercased()
        let valid = ["mlpackage", "mlmodelc", "mlmodel"]
        guard valid.contains(ext) else {
            throw Error.invalidModelFile(
                "Expected a .mlpackage, .mlmodelc, or .mlmodel — got .\(ext.isEmpty ? "(none)" : ext)."
            )
        }

        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Wigglegram/models", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let dest = dir.appendingPathComponent("sharp.\(ext)")
        // Stage into a temp sibling first so the copy is atomic — a
        // partially-copied 2.5 GB mlpackage would brick the app.
        let staging = dir.appendingPathComponent(
            "sharp.\(ext).staging-\(UUID().uuidString.prefix(6))"
        )

        // Copy on a background task; mlpackage copies are big.
        try await Task.detached(priority: .userInitiated) {
            try fm.copyItem(at: sourceURL, to: staging)
        }.value

        // Remove any existing install (even if it's a different ext,
        // since we want a clean slate) + the compiled cache.
        for candidate in valid {
            let old = dir.appendingPathComponent("sharp.\(candidate)")
            if fm.fileExists(atPath: old.path) {
                try fm.removeItem(at: old)
            }
        }
        let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Wigglegram", isDirectory: true)
        let compiledPath = cacheRoot.appendingPathComponent("sharp.mlmodelc")
        if fm.fileExists(atPath: compiledPath.path) {
            try? fm.removeItem(at: compiledPath)
        }

        try fm.moveItem(at: staging, to: dest)
        return dest
    }

    // MARK: - Inference

    func runInference(
        imageURL: URL,
        focalLengthPx: Float?,
        progressHandler: @Sendable (String) -> Void = { _ in }
    ) async throws -> (cloud: GaussianCloud, frustum: SourceFrustum) {
        guard let model = lock.withLock({ model }) else { throw Error.modelNotLoaded }

        let size = Self.modelInputSize
        let capturedURL = imageURL

        let (cgImage, actualWidth, actualHeight) = try await Task.detached(priority: .userInitiated) {
            guard let nsImage = NSImage(contentsOf: capturedURL),
                  let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { throw Error.imageLoadFailed(capturedURL.path) }
            return (cg, cg.width, cg.height)
        }.value

        let focalPx = focalLengthPx ?? Float(size)
        // Convert focal from original pixels to the model's input scale,
        // then divide by width to produce SHARP's "disparity_factor" input.
        let fOrig = focalPx * Float(actualWidth) / Float(size)
        let disparityFactor = fOrig / Float(actualWidth)
        // Diagnostic: on first real photo, these numbers tell us whether
        // the focal assumption is sane. Expect disparityFactor ~ 1.0 for
        // the default focalLengthPx = modelInputSize case.
        NSLog("[SHARP] input=%dx%d focalPx=%.1f fOrig=%.1f disparityFactor=%.4f",
              actualWidth, actualHeight, focalPx, fOrig, disparityFactor)

        progressHandler("Preprocessing…")
        let imageArray = try await Task.detached(priority: .userInitiated) {
            try Self.preprocess(from: cgImage, size: size)
        }.value

        progressHandler("Running SHARP…")
        let disparityArray = try MLMultiArray(shape: [1], dataType: .float32)
        disparityArray[0] = NSNumber(value: disparityFactor)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: imageArray),
            "disparity_factor": MLFeatureValue(multiArray: disparityArray)
        ])
        let output = try await model.prediction(from: input)

        progressHandler("Extracting gaussians…")
        let outDesc = model.modelDescription.outputDescriptionsByName
        let cloudNDC = try await Task.detached(priority: .userInitiated) {
            try Self.extractGaussians(from: output, modelOutputs: outDesc)
        }.value

        progressHandler("Unprojecting…")
        let cloud = await Task.detached(priority: .userInitiated) {
            Self.unprojectGaussians(
                cloudNDC,
                focalLengthPx: focalPx,
                modelInputSize: size,
                originalWidth: actualWidth,
                originalHeight: actualHeight
            )
        }.value

        let frustum = SourceFrustum(
            imageWidth: actualWidth,
            imageHeight: actualHeight,
            focalLengthPx: fOrig
        )
        return (cloud, frustum)
    }

    // MARK: - Model location

    private func resolveModelURL() throws -> URL {
        let fm = FileManager.default

        // Prefer the pre-compiled mlmodelc that Xcode drops into the bundle
        // when a .mlpackage is added as a resource — loading it is instant
        // and skips compileModelIfNeeded entirely.
        if let bundleURL = Bundle.main.url(forResource: "sharp", withExtension: "mlmodelc"),
           fm.fileExists(atPath: bundleURL.path) {
            return bundleURL
        }
        if let bundleURL = Bundle.main.url(forResource: "sharp", withExtension: "mlpackage"),
           fm.fileExists(atPath: bundleURL.path) {
            return bundleURL
        }

        let overrideDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Wigglegram/models", isDirectory: true)
        for candidate in ["sharp.mlmodelc", "sharp.mlpackage", "sharp.mlmodel"] {
            let url = overrideDir.appendingPathComponent(candidate)
            if fm.fileExists(atPath: url.path) { return url }
        }

        throw Error.modelNotFound(
            """
            SHARP model not found. Expected either:
              • bundled inside Wigglegram.app/Contents/Resources/sharp.mlpackage
              • or at \(overrideDir.path)/sharp.mlpackage
            Download from https://huggingface.co/pearsonkyle/Sharp-coreml and place accordingly.
            """
        )
    }

    private func compileModelIfNeeded(at modelPath: URL) async throws -> URL {
        let ext = modelPath.pathExtension.lowercased()
        if ext == "mlmodelc" { return modelPath }

        let fm = FileManager.default
        let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Wigglegram", isDirectory: true)
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let compiledPath = cacheRoot.appendingPathComponent("sharp.mlmodelc")

        if fm.fileExists(atPath: compiledPath.path) {
            let src = try fm.attributesOfItem(atPath: modelPath.path)
            let dst = try fm.attributesOfItem(atPath: compiledPath.path)
            if let s = src[.modificationDate] as? Date, let d = dst[.modificationDate] as? Date, d >= s {
                return compiledPath
            }
            try? fm.removeItem(at: compiledPath)
        }

        let tmp = try await MLModel.compileModel(at: modelPath)
        try? fm.removeItem(at: compiledPath)
        try fm.moveItem(at: tmp, to: compiledPath)
        return compiledPath
    }

    // MARK: - Preprocess

    private static func preprocess(from cgImage: CGImage, size: Int) throws -> MLMultiArray {
        // Resize to size x size (SHARP's fixed input) and pack into
        // a [1, 3, H, W] float32 MLMultiArray in 0..1 range.
        let ciImage = CIImage(cgImage: cgImage)
        let ctx = CIContext()
        let scaled = ciImage.transformed(by: CGAffineTransform(
            scaleX: CGFloat(size) / ciImage.extent.width,
            y: CGFloat(size) / ciImage.extent.height
        ))
        guard let resized = ctx.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: size, height: size))
        else { throw Error.imageLoadFailed("Resize failed") }

        let imageArray = try MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        )

        let bpp = 4
        let bpr = bpp * size
        var pixelData = [UInt8](repeating: 0, count: size * bpr)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgCtx = CGContext(
            data: &pixelData, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Error.imageLoadFailed("Bitmap context creation failed") }
        cgCtx.draw(resized, in: CGRect(x: 0, y: 0, width: size, height: size))

        let ptr = imageArray.dataPointer.assumingMemoryBound(to: Float.self)
        let stride = size * size
        for y in 0..<size {
            for x in 0..<size {
                let pi = y * bpr + x * bpp
                let si = y * size + x
                ptr[0 * stride + si] = Float(pixelData[pi]) / 255.0
                ptr[1 * stride + si] = Float(pixelData[pi + 1]) / 255.0
                ptr[2 * stride + si] = Float(pixelData[pi + 2]) / 255.0
            }
        }
        return imageArray
    }

    // MARK: - Output extraction (from SharpSplat, float32 fast path only)

    private static func extractGaussians(
        from output: MLFeatureProvider,
        modelOutputs: [String: MLFeatureDescription]
    ) throws -> GaussianCloud {
        let names = Array(modelOutputs.keys)

        func find(_ keywords: [String]) -> MLMultiArray? {
            for name in names {
                let lower = name.lowercased()
                for kw in keywords where lower.contains(kw.lowercased()) {
                    return output.featureValue(for: name)?.multiArrayValue
                }
            }
            return nil
        }

        guard let meanVec = output.featureValue(for: "mean_vectors_3d_positions")?.multiArrayValue
                ?? find(["mean_vectors", "mean", "position"]),
              let singVal = output.featureValue(for: "singular_values_scales")?.multiArrayValue
                ?? find(["singular_values", "singular", "scale"]),
              let quats = output.featureValue(for: "quaternions_rotations")?.multiArrayValue
                ?? find(["quaternion", "rotation"]),
              let cols = output.featureValue(for: "colors_rgb_linear")?.multiArrayValue
                ?? find(["colors", "color", "rgb"]),
              let opacs = output.featureValue(for: "opacities_alpha_channel")?.multiArrayValue
                ?? find(["opacities", "opaci", "alpha"])
        else { throw Error.outputExtractionFailed(names) }

        let n = meanVec.shape[1].intValue

        var positions = [SIMD3<Float>](repeating: .zero, count: n)
        var scales = [SIMD3<Float>](repeating: .zero, count: n)
        var rotations = [simd_quatf](repeating: .init(ix: 0, iy: 0, iz: 0, r: 1), count: n)
        var colors = [SIMD3<Float>](repeating: .zero, count: n)
        var opacities = [Float](repeating: 0, count: n)

        let fast = meanVec.dataType == .float32 && singVal.dataType == .float32 &&
                   quats.dataType == .float32 && cols.dataType == .float32 &&
                   opacs.dataType == .float32 &&
                   meanVec.strides.count >= 3 && singVal.strides.count >= 3 &&
                   quats.strides.count >= 3 && cols.strides.count >= 3 &&
                   opacs.strides.count >= 2

        if fast {
            let mP = meanVec.dataPointer.assumingMemoryBound(to: Float.self)
            let sP = singVal.dataPointer.assumingMemoryBound(to: Float.self)
            let qP = quats.dataPointer.assumingMemoryBound(to: Float.self)
            let cP = cols.dataPointer.assumingMemoryBound(to: Float.self)
            let oP = opacs.dataPointer.assumingMemoryBound(to: Float.self)

            let mS1 = meanVec.strides[1].intValue, mS2 = meanVec.strides[2].intValue
            let sS1 = singVal.strides[1].intValue, sS2 = singVal.strides[2].intValue
            let qS1 = quats.strides[1].intValue, qS2 = quats.strides[2].intValue
            let cS1 = cols.strides[1].intValue, cS2 = cols.strides[2].intValue
            let oS1 = opacs.strides[1].intValue

            for i in 0..<n {
                let mB = i * mS1
                positions[i] = SIMD3(mP[mB], mP[mB + mS2], mP[mB + 2 * mS2])
                let sB = i * sS1
                scales[i] = SIMD3(sP[sB], sP[sB + sS2], sP[sB + 2 * sS2])
                let qB = i * qS1
                rotations[i] = simd_quatf(
                    ix: qP[qB + qS2], iy: qP[qB + 2 * qS2], iz: qP[qB + 3 * qS2], r: qP[qB]
                )
                let cB = i * cS1
                colors[i] = SIMD3(cP[cB], cP[cB + cS2], cP[cB + 2 * cS2])
                opacities[i] = oP[i * oS1]
            }
        } else {
            let b0: NSNumber = 0
            for i in 0..<n {
                let idx = NSNumber(value: i)
                positions[i] = SIMD3(
                    meanVec[[b0, idx, 0] as [NSNumber]].floatValue,
                    meanVec[[b0, idx, 1] as [NSNumber]].floatValue,
                    meanVec[[b0, idx, 2] as [NSNumber]].floatValue
                )
                scales[i] = SIMD3(
                    singVal[[b0, idx, 0] as [NSNumber]].floatValue,
                    singVal[[b0, idx, 1] as [NSNumber]].floatValue,
                    singVal[[b0, idx, 2] as [NSNumber]].floatValue
                )
                rotations[i] = simd_quatf(
                    ix: quats[[b0, idx, 1] as [NSNumber]].floatValue,
                    iy: quats[[b0, idx, 2] as [NSNumber]].floatValue,
                    iz: quats[[b0, idx, 3] as [NSNumber]].floatValue,
                    r: quats[[b0, idx, 0] as [NSNumber]].floatValue
                )
                colors[i] = SIMD3(
                    cols[[b0, idx, 0] as [NSNumber]].floatValue,
                    cols[[b0, idx, 1] as [NSNumber]].floatValue,
                    cols[[b0, idx, 2] as [NSNumber]].floatValue
                )
                opacities[i] = opacs[[b0, idx] as [NSNumber]].floatValue
            }
        }

        return GaussianCloud(
            positions: positions, scales: scales, rotations: rotations,
            colors: colors, opacities: opacities
        )
    }

    // MARK: - Unproject (from SharpSplat v4 Y-up frame)

    private static func unprojectGaussians(
        _ cloud: GaussianCloud,
        focalLengthPx: Float,
        modelInputSize: Int,
        originalWidth: Int,
        originalHeight: Int
    ) -> GaussianCloud {
        let fOrig = focalLengthPx * Float(originalWidth) / Float(modelInputSize)
        let W = Float(originalWidth)
        let H = Float(originalHeight)

        // SHARP emits Y-up positions with the per-pixel-ray parametrization
        // used in SharpSplat v4 (see SharpSplat/Services/SHARPInferenceService.swift).
        let sX = W / (2.0 * fOrig)
        let sY = H / (2.0 * fOrig)

        var positions = [SIMD3<Float>](repeating: .zero, count: cloud.count)
        var scales = [SIMD3<Float>](repeating: .zero, count: cloud.count)
        for i in 0..<cloud.count {
            let p = cloud.positions[i]
            positions[i] = SIMD3(p.x * sX, p.y * sY, p.z)
            let sv = cloud.scales[i]
            scales[i] = SIMD3(sv.x * sX, sv.y * sY, sv.z)
        }
        return GaussianCloud(
            positions: positions, scales: scales, rotations: cloud.rotations,
            colors: cloud.colors, opacities: cloud.opacities
        )
    }
}
