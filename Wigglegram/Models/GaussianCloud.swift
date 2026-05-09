import Foundation
import simd

nonisolated struct GaussianCloud: Sendable {
    var positions: [SIMD3<Float>]
    var scales: [SIMD3<Float>]
    var rotations: [simd_quatf]
    var colors: [SIMD3<Float>]
    var opacities: [Float]

    var count: Int { positions.count }

    static let empty = GaussianCloud(
        positions: [], scales: [], rotations: [], colors: [], opacities: []
    )

    struct BoundingBox: Sendable {
        var min: SIMD3<Float>
        var max: SIMD3<Float>
        var center: SIMD3<Float> { (min + max) * 0.5 }
        var extent: SIMD3<Float> { max - min }
        var diagonal: Float { simd_length(extent) }
    }

    var boundingBox: BoundingBox {
        guard count > 0 else { return BoundingBox(min: .zero, max: .zero) }
        var bbMin = positions[0]
        var bbMax = positions[0]
        for i in 1..<count {
            bbMin = simd_min(bbMin, positions[i])
            bbMax = simd_max(bbMax, positions[i])
        }
        return BoundingBox(min: bbMin, max: bbMax)
    }

    /// Median of splat depths along the camera's forward axis
    /// (i.e. `abs(z)` in SHARP's camera-aligned coordinates). Used as
    /// the convergence distance for rotate-style wiggles so all virtual
    /// lenses toe-in on a physically reasonable pivot.
    var medianDepth: Float {
        guard count > 0 else { return 1 }
        var depths = positions.map { abs($0.z) }
        depths.sort()
        return depths[depths.count / 2]
    }
}

/// The pinhole frustum of the photo that produced a `GaussianCloud`.
/// Preserved through SHARP so downstream code can place the virtual
/// wigglegram-camera base pose exactly at the original photo's
/// viewpoint — anything else sees the edges of the per-pixel-ray splat
/// reconstruction and reads as "a splat, not a photo."
nonisolated struct SourceFrustum: Sendable, Equatable {
    /// Original image width in pixels.
    var imageWidth: Int
    /// Original image height in pixels.
    var imageHeight: Int
    /// Focal length in original-image pixels (matches `fOrig` in
    /// `SHARPInferenceService.unprojectGaussians`).
    var focalLengthPx: Float

    /// Vertical FoV recovered from the pinhole model. The photo is
    /// reproduced when the camera sits at the origin, looks down +Z,
    /// and uses this `fovY` with aspect = width/height.
    var fovY: Float {
        2 * atan(Float(imageHeight) / (2 * focalLengthPx))
    }

    var aspect: Float {
        Float(imageWidth) / Float(imageHeight)
    }
}
