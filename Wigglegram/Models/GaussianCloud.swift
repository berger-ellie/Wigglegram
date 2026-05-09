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
}
