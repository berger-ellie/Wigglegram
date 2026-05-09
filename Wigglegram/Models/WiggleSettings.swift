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
    /// Wiggle cycle rate in Hz — full ping-pong cycles per second.
    /// Was previously `fps` (per-frame), which made the perceived speed
    /// of the animation change with `frameCount` even when the slider
    /// didn't move. Using cycles-per-second decouples the two: a 3 Hz
    /// wiggle looks the same regardless of whether it's a 2-lens
    /// cycle (short ping-pong) or a 15-lens cycle (long ping-pong).
    /// Derived fps for playback/export = `cycleHz * pingPongSteps`,
    /// where `pingPongSteps = max(1, 2*(frameCount-1))`.
    var cycleHz: Float = 3.0
    /// Number of distinct baked frames. Real wigglegram cameras have
    /// 3-4 lenses; we allow 2-15.
    var frameCount: Int = 4
    var style: Style = .shiftHorizontal

    /// How many discrete steps a full ping-pong cycle traverses.
    /// `0, 1, ..., N-1, N-2, ..., 1` → `2*(N-1)` steps for N > 1;
    /// clamped to 1 when N ≤ 1 to keep the fps divisor safe.
    var pingPongSteps: Int { max(1, 2 * (frameCount - 1)) }

    /// Playback fps derived from `cycleHz` and `frameCount`. This is
    /// what `FramePlayerView` ticks at and what `WiggleExporter`
    /// embeds in the MP4/GIF header.
    var playbackFps: Int {
        max(1, Int((cycleHz * Float(pingPongSteps)).rounded()))
    }
}
