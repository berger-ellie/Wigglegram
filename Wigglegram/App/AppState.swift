import Foundation
import SwiftUI
import AppKit
import simd

/// The single place where app state lives. Runs on the main actor so
/// SwiftUI observes property changes without any extra plumbing.
@MainActor
@Observable
final class AppState {
    enum Stage: Equatable {
        case idle
        case loadingModel
        case ready
        case loadingImage(String)
        case processing(String)
        case displaying
        case exporting(progress: Double)
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Starting up…"
            case .loadingModel: "Loading SHARP…"
            case .ready: "Drop a photo to begin."
            case .loadingImage(let s): s
            case .processing(let s): s
            case .displaying: "Ready — tune the wiggle or export."
            case .exporting(let p): "Exporting… \(Int(p * 100))%"
            case .failed(let m): "Failed: \(m)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .loadingModel, .loadingImage, .processing, .exporting: true
            default: false
            }
        }
    }

    let sharp = SHARPInferenceService()
    var stage: Stage = .idle
    var wiggle = WiggleSettings()
    var camera: CameraPose = .default
    /// Path to the most recently generated PLY, used by the viewer.
    var splatURL: URL?
    var sourceImageURL: URL?
    /// Updated by a timer while `displaying` to produce the live wiggle.
    var animationStart: Date = .distantPast

    func warmUpModel() async {
        guard case .idle = stage else { return }
        stage = .loadingModel
        do {
            try await sharp.loadModel()
            stage = .ready
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Resets everything but the loaded model so we can drop another photo.
    func reset() {
        splatURL = nil
        sourceImageURL = nil
        stage = sharp.isModelLoaded ? .ready : .idle
    }

    /// Full pipeline: image → SHARP → PLY on disk → viewer.
    func processImage(at url: URL) async {
        guard sharp.isModelLoaded else {
            stage = .failed("SHARP not loaded yet.")
            return
        }
        sourceImageURL = url
        splatURL = nil
        stage = .loadingImage("Loading photo…")

        do {
            stage = .processing("Running SHARP on \(url.lastPathComponent)…")
            let cloud = try await sharp.runInference(
                imageURL: url, focalLengthPx: nil
            ) { [weak self] msg in
                Task { @MainActor in self?.stage = .processing(msg) }
            }

            stage = .processing("Writing splat…")
            let plyURL = try writeSplatPLY(cloud: cloud, sourceName: url.deletingPathExtension().lastPathComponent)
            splatURL = plyURL
            // Re-frame the camera so typical SHARP output (subject around
            // origin, scenes spanning ~1-3 units) is nicely framed.
            camera = frameCamera(for: cloud)
            animationStart = Date()
            stage = .displaying
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    private func writeSplatPLY(cloud: GaussianCloud, sourceName: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wigglegram", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("\(sourceName)-\(UUID().uuidString.prefix(6)).ply")
        try GaussianIO.savePLY(cloud: cloud, to: url)
        return url
    }

    private func frameCamera(for cloud: GaussianCloud) -> CameraPose {
        // Note: viewer flips Y on load, so frame against the flipped cloud.
        guard cloud.count > 0 else { return .default }
        let bbox = cloud.boundingBox
        // Use the median depth plus a margin so we're always in front of
        // the splat rather than inside it. SHARP outputs roughly metric
        // scale once we've unprojected.
        let centerFlipped = SIMD3<Float>(bbox.center.x, -bbox.center.y, bbox.center.z)
        let diag = max(bbox.diagonal, 0.5)
        var pose = CameraPose.default
        pose.target = centerFlipped
        pose.distance = diag * 0.9
        pose.yaw = 0
        pose.pitch = 0
        return pose
    }
}
