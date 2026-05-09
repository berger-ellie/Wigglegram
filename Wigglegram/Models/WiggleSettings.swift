import Foundation
import simd

/// Describes the wiggle animation and emits camera poses as a function
/// of a [0,1] phase.
struct WiggleSettings: Equatable, Codable {
    enum Style: String, CaseIterable, Identifiable, Codable {
        case horizontal, vertical, circle, figureEight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .horizontal: "Horizontal"
            case .vertical: "Vertical"
            case .circle: "Circle"
            case .figureEight: "Figure 8"
            }
        }
    }

    /// Max angular offset from center, in degrees.
    var amplitudeDegrees: Float = 4.0
    /// Render FPS for export and preview.
    var fps: Int = 30
    /// Number of unique frames in one loop.
    var frameCount: Int = 30
    var style: Style = .horizontal

    /// Camera pose for phase `t` ∈ [0, 1] around `base`. One full period.
    func pose(at t: Float, base: CameraPose) -> CameraPose {
        var p = base
        let amp = amplitudeDegrees * .pi / 180
        let theta = 2 * .pi * t
        switch style {
        case .horizontal:
            p.yaw += amp * sin(theta)
        case .vertical:
            p.pitch += amp * sin(theta)
        case .circle:
            p.yaw += amp * sin(theta)
            p.pitch += amp * cos(theta)
        case .figureEight:
            p.yaw += amp * sin(theta)
            p.pitch += amp * sin(2 * theta) * 0.5
        }
        return p
    }
}
