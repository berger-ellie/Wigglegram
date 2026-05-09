import Foundation
import simd

/// Computes the discrete set of camera poses that represent each
/// "lens" of the virtual wigglegram camera. Given `frameCount = N`,
/// returns exactly N poses centered around `base`, symmetric about
/// the midpoint, so index i maps to offset `(i / (N-1)) - 0.5` in
/// [-0.5, 0.5]. With a single frame, we just return `[base]`.
///
/// All four styles share a single `frameDistance` baseline (total
/// separation between the two extreme lenses, in meters). Shift
/// styles translate the whole rig in parallel; rotate styles keep
/// the base target fixed and toe-in every lens on the convergence
/// point. This matches how physical wigglegram cameras behave — each
/// lens sits on a shared baseline and aims at the subject.
enum WiggleCamera {
    /// - Parameters:
    ///   - base: framing pose at the source photo's viewpoint.
    ///   - settings: style + frameCount + frameDistance.
    ///   - convergence: distance (meters) along `base.forward` where
    ///     rotate lenses converge. Typically the scene's median depth.
    /// - Returns: `settings.frameCount` poses, ordered.
    static func poses(
        base: CameraPose,
        settings: WiggleSettings,
        convergence: Float
    ) -> [CameraPose] {
        let n = max(1, settings.frameCount)
        if n == 1 { return [base] }

        let offsets: [Float] = (0..<n).map { i in
            Float(i) / Float(n - 1) - 0.5
        }

        switch settings.style {
        case .shiftHorizontal:
            return offsets.map { shift(base: base, offset: $0 * settings.frameDistance, axis: base.right) }
        case .shiftVertical:
            return offsets.map { shift(base: base, offset: $0 * settings.frameDistance, axis: base.up) }
        case .rotateHorizontal:
            return offsets.map {
                toeIn(base: base,
                      lateralOffset: $0 * settings.frameDistance,
                      direction: .horizontal,
                      convergence: convergence)
            }
        case .rotateVertical:
            return offsets.map {
                toeIn(base: base,
                      lateralOffset: $0 * settings.frameDistance,
                      direction: .vertical,
                      convergence: convergence)
            }
        }
    }

    private enum RotateDirection { case horizontal, vertical }

    /// Parallel-rig shift: eye and target translate by the same vector,
    /// so the camera keeps its forward direction. Works cleanly because
    /// `CameraPose.eye = target - distance * forward`, and translating
    /// `target` by any vector translates `eye` by the same amount.
    private static func shift(base: CameraPose, offset: Float, axis: SIMD3<Float>) -> CameraPose {
        var p = base
        p.target = base.target + axis * offset
        return p
    }

    /// Toe-in rotate: the eye slides along the chosen camera-space axis
    /// by `lateralOffset` while the camera keeps pointing at the
    /// convergence point. We re-derive `target`, `distance`, `yaw`, and
    /// `pitch` so the resulting `CameraPose.eye` matches the desired
    /// position and `CameraPose.viewMatrix()` aims at the pivot.
    ///
    /// Assumes `base.yaw == 0 && base.pitch == 0` (true for the source-
    /// frustum base pose).
    private static func toeIn(
        base: CameraPose,
        lateralOffset d: Float,
        direction: RotateDirection,
        convergence c: Float
    ) -> CameraPose {
        let axis = direction == .horizontal ? base.right : base.up
        let pivot = base.eye + base.forward * c
        let newEye = base.eye + axis * d
        let delta = pivot - newEye
        let distance = length(delta)

        var p = base
        p.target = pivot
        p.distance = distance

        switch direction {
        case .horizontal:
            p.pitch = 0
            p.yaw = atan2(d, c)
        case .vertical:
            p.yaw = 0
            p.pitch = atan2(d, c)
        }
        return p
    }
}
