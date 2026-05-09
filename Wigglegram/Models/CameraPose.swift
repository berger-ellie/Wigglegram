import Foundation
import simd

/// Pinhole camera pose used by both the live viewer (removed) and the
/// offscreen `FrameBaker`. Extracted out of `SplatViewer.swift` so it
/// can be referenced from services/models without pulling in SwiftUI.
///
/// Convention (matches SHARP / SharpSplat): scene sits on +Z from the
/// camera's perspective. At `yaw=0, pitch=0, target=.zero` the eye sits
/// at `(0, 0, -distance)` looking toward `+Z`. This was the bug in the
/// pre-baker version — the eye was at `+Z`, which showed the splat from
/// behind.
struct CameraPose: Equatable {
    var target: SIMD3<Float>
    var distance: Float
    /// Horizontal rotation about `target`, radians. 0 = looking down +Z.
    var yaw: Float
    /// Vertical rotation about `target`, radians.
    var pitch: Float
    var fovY: Float

    static let `default` = CameraPose(
        target: .zero, distance: 2.2, yaw: 0, pitch: 0.0, fovY: .pi / 4
    )

    /// Eye position derived from (target, distance, yaw, pitch). We put
    /// the eye at -Z when yaw=pitch=0 so the camera "looks into" the scene.
    var eye: SIMD3<Float> {
        target + SIMD3<Float>(
            distance * cos(pitch) * sin(yaw),
            distance * sin(pitch),
            -distance * cos(pitch) * cos(yaw)
        )
    }

    /// Unit vector from eye toward target (the camera's forward axis).
    var forward: SIMD3<Float> { normalize(target - eye) }

    /// Camera right axis (world space). Matches the right-handed
    /// convention in `lookAt`: with forward=+Z and up=+Y, `right = +X`,
    /// so `shift(offset * right)` moves the rig rightward in the photo.
    var right: SIMD3<Float> {
        normalize(cross(SIMD3<Float>(0, 1, 0), forward))
    }

    /// Camera up axis (in world space).
    var up: SIMD3<Float> { normalize(cross(forward, right)) }

    func viewMatrix() -> simd_float4x4 {
        lookAt(eye: eye, center: target, up: SIMD3(0, 1, 0))
    }
}

func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let yScale = 1 / tan(fovY * 0.5)
    let xScale = yScale / aspect
    let zRange = far - near
    return simd_float4x4(columns: (
        SIMD4(xScale, 0, 0, 0),
        SIMD4(0, yScale, 0, 0),
        SIMD4(0, 0, -(far + near) / zRange, -1),
        SIMD4(0, 0, -2 * far * near / zRange, 0)
    ))
}

func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    // Right-handed lookAt: in view space, the camera looks down -Z,
    // world +X maps to view +X, world +Y maps to view +Y. The
    // previously-used `cross(f, up)` variant silently flipped both X
    // and Y, which rendered the scene both horizontally mirrored and
    // upside-down. We documented that as a SHARP-vs-lookAt convention
    // clash and compensated with a `y = -y` map in `FrameBaker.loadCloud`,
    // but that only addressed the Y flip — the X mirror leaked through
    // into the baked frames.
    let f = normalize(center - eye)
    let s = normalize(cross(up, f))
    let u = cross(f, s)
    return simd_float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    ))
}
