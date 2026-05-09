import Foundation
import simd

/// Describes the wiggle animation as a discrete set of camera poses.
/// The live parametric `pose(at t:)` is gone — we now always enumerate
/// `frameCount` discrete poses and cache them as prerendered images.
struct WiggleSettings: Equatable, Codable {
    enum Style: String, CaseIterable, Identifiable, Codable {
        case shiftHorizontal, shiftVertical, rotateHorizontal, rotateVertical
        var id: String { rawValue }
        var label: String {
            switch self {
            case .shiftHorizontal: "H Shift"
            case .shiftVertical: "V Shift"
            case .rotateHorizontal: "H Rotate"
            case .rotateVertical: "V Rotate"
            }
        }
        var isTranslation: Bool {
            self == .shiftHorizontal || self == .shiftVertical
        }
    }

    /// Total distance (meters) between the two extreme lens positions.
    /// Applies to all four styles: shift styles translate the whole rig
    /// by this much along right/up; rotate styles place the lenses
    /// laterally at this baseline and toe-in on the convergence point.
    /// Real wigglegram cameras are ~15-30 mm apart per lens; defaulting
    /// to 3 cm total feels close to that without blowing past SHARP's
    /// coverage cone. UI slider is in cm; this is the meters value.
    var frameDistance: Float = 0.03
    /// Playback rate in frames per second. Only affects the preview
    /// timer and export timing; never triggers a rebake.
    var fps: Int = 6
    /// Number of distinct baked frames. Real wigglegram cameras have
    /// 3-4 lenses; we allow 2-15.
    var frameCount: Int = 4
    var style: Style = .shiftHorizontal
}
