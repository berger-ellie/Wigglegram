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
        /// A photo was dropped before the model finished loading; it'll
        /// be processed automatically once the model is ready.
        case pendingImage(URL)
        case loadingImage(String)
        case processing(String)
        case baking(done: Int, total: Int)
        case displaying
        case exporting(progress: Double)
        case failed(String)

        var label: String {
            switch self {
            case .idle: "Starting up…"
            case .loadingModel: "Loading SHARP…"
            case .ready: "Drop a photo to begin."
            case .pendingImage: "Waiting for model…"
            case .loadingImage(let s): s
            case .processing(let s): s
            case .baking(let d, let t): "Baking frames \(d)/\(t)…"
            case .displaying: "Ready — tune the wiggle or export."
            case .exporting(let p): "Exporting… \(Int(p * 100))%"
            case .failed(let m): "Failed: \(m)"
            }
        }

        var isBusy: Bool {
            switch self {
            case .loadingModel, .pendingImage, .loadingImage, .processing, .baking, .exporting: true
            default: false
            }
        }
    }

    let sharp = SHARPInferenceService()
    var stage: Stage = .idle
    var wiggle = WiggleSettings() {
        didSet { handleWiggleChange(old: oldValue) }
    }
    var camera: CameraPose = .default
    /// Path to the most recently generated PLY (kept so we can rebuild
    /// the baker on relaunch or after explicit rebake).
    var splatURL: URL?
    var sourceImageURL: URL?
    /// The dropped photo, decoded. Shown in the preview frame
    /// immediately while SHARP runs, and as the fallback when no frames
    /// have been baked yet.
    var sourceImage: NSImage?
    /// Pinhole frustum of the most recently processed photo. Used to
    /// place the virtual camera exactly at the photo viewpoint, which is
    /// the only pose that reproduces SHARP's per-pixel-ray reconstruction
    /// without showing the edges of the splat.
    var sourceFrustum: SourceFrustum?
    /// Median splat depth of the currently loaded cloud. Used as the
    /// convergence distance for rotate-style wiggles so the virtual
    /// lenses toe-in on a sensible subject pivot.
    var convergenceDistance: Float = 1
    /// Prerendered frames at the current `wiggle` geometry. Empty while
    /// loading / baking.
    var frames: [CGImage] = []

    /// True when a SHARP install is being staged from disk. Read by the
    /// settings sheet to show a spinner / disable the drop zone while
    /// `installSHARPModel` is in flight.
    var isInstallingModel: Bool = false
    /// Transient confirmation message from the most recent settings-side
    /// action (install / unload). Cleared after a short timeout.
    var settingsMessage: String?

    private var baker: FrameBaker?
    private var bakeTask: Task<Void, Never>?
    private var rebakeDebounceTask: Task<Void, Never>?

    /// Shortest-axis size (px) for preview bakes. The other axis is
    /// sized to preserve the source photo's aspect ratio; baking at a
    /// non-source aspect exposes the edges of SHARP's per-pixel-ray
    /// frustum (black borders around the splat) and squashes the
    /// subject.
    private let bakeSize = 768

    /// Cap the long edge at this × `bakeSize` so extreme aspect ratios
    /// (e.g. panoramas) don't blow out the render texture.
    private let bakeAspectClamp: Float = 2.0

    /// Preview bake dimensions for the currently-loaded photo. Returns
    /// the canonical square size until we have a frustum.
    private var bakeDimensions: (width: Int, height: Int) {
        guard let f = sourceFrustum, f.imageWidth > 0, f.imageHeight > 0 else {
            return (bakeSize, bakeSize)
        }
        let aspect = max(1 / bakeAspectClamp, min(bakeAspectClamp, f.aspect))
        if aspect >= 1 {
            let w = Int((Float(bakeSize) * aspect).rounded())
            return (w, bakeSize)
        } else {
            let h = Int((Float(bakeSize) / aspect).rounded())
            return (bakeSize, h)
        }
    }

    func warmUpModel() async {
        // Allow re-entry from pendingImage so it runs the queued image.
        if case .pendingImage(let u) = stage, sharp.isModelLoaded {
            await processImage(at: u)
            return
        }
        switch stage {
        case .idle, .loadingModel:
            break
        default:
            return
        }
        stage = .loadingModel
        do {
            try await sharp.loadModel()
            if case .pendingImage(let url) = stage {
                await processImage(at: url)
            } else {
                stage = .ready
            }
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    /// Settings-panel entry point: stage a user-provided model bundle
    /// into Application Support, drop the currently-loaded model, and
    /// reload from the fresh install. Leaves the app in either
    /// `.ready` (on success) or `.failed` (on copy/load error).
    ///
    /// Accepts the same bundle types as `SHARPInferenceService.installModel`:
    /// `.mlpackage`, `.mlmodelc`, or `.mlmodel`.
    func installSHARPModel(from sourceURL: URL) async {
        guard !isInstallingModel else { return }
        isInstallingModel = true
        settingsMessage = nil
        defer { isInstallingModel = false }

        // Discard any queued work — the new model will reconstruct the
        // cloud from scratch, so holding on to stale splat/frames is
        // actively misleading.
        bakeTask?.cancel()
        rebakeDebounceTask?.cancel()
        frames = []
        splatURL = nil
        sourceFrustum = nil
        sharp.unloadModel()
        stage = .loadingModel

        do {
            let installed = try await sharp.installModel(from: sourceURL)
            try await sharp.loadModel()
            settingsMessage = "Installed \(installed.lastPathComponent)"
            // If a photo was already on screen, immediately re-process
            // it against the new model; otherwise just sit at `.ready`.
            if let queued = sourceImageURL {
                await processImage(at: queued)
            } else {
                stage = .ready
            }
        } catch {
            settingsMessage = "Install failed: \(error.localizedDescription)"
            stage = .failed(error.localizedDescription)
        }
    }

    /// Resets everything but the loaded model so we can drop another photo.
    func reset() {
        bakeTask?.cancel()
        rebakeDebounceTask?.cancel()
        splatURL = nil
        sourceImageURL = nil
        sourceImage = nil
        sourceFrustum = nil
        convergenceDistance = 1
        frames = []
        Task { [baker] in await baker?.unload() }
        stage = sharp.isModelLoaded ? .ready : .idle
    }

    /// Full pipeline: image → sourceImage (immediate) → SHARP → PLY →
    /// FrameBaker load → rebake frames.
    func processImage(at url: URL) async {
        // Show the photo immediately, before anything else runs.
        sourceImageURL = url
        sourceImage = NSImage(contentsOf: url)
        frames = []

        guard sharp.isModelLoaded else {
            stage = .pendingImage(url)
            return
        }

        splatURL = nil

        do {
            stage = .processing("Running SHARP on \(url.lastPathComponent)…")
            let (cloud, frustum) = try await sharp.runInference(
                imageURL: url, focalLengthPx: nil
            ) { [weak self] msg in
                Task { @MainActor [weak self] in self?.stage = .processing(msg) }
            }

            stage = .processing("Writing splat…")
            let plyURL = try writeSplatPLY(cloud: cloud, sourceName: url.deletingPathExtension().lastPathComponent)
            splatURL = plyURL
            sourceFrustum = frustum
            convergenceDistance = cloud.medianDepth
            camera = frameCamera(for: frustum)
            NSLog("[Wigglegram] cloud count=%d medianDepth=%.3f frustum=%dx%d fOrig=%.1f fovY=%.1fdeg",
                  cloud.count, cloud.medianDepth,
                  frustum.imageWidth, frustum.imageHeight, frustum.focalLengthPx,
                  frustum.fovY * 180 / .pi)

            stage = .processing("Preparing renderer…")
            let b = try ensureBaker()
            try await b.loadCloud(plyURL: plyURL)
            await rebakeFrames()
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Baking

    /// Called when sliders that affect geometry change. Debounces
    /// 250ms, cancels any in-flight bake, and re-renders.
    func scheduleRebake() {
        rebakeDebounceTask?.cancel()
        rebakeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.rebakeFrames()
        }
    }

    /// Cancel any in-flight bake and kick off a new one against the
    /// current `wiggle` + `camera`.
    func rebakeFrames() async {
        guard let b = baker, b.isLoaded else { return }
        bakeTask?.cancel()
        bakeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let poses = WiggleCamera.poses(
                base: self.camera,
                settings: self.wiggle,
                convergence: self.convergenceDistance
            )
            let dims = self.bakeDimensions
            self.stage = .baking(done: 0, total: poses.count)
            do {
                let rendered = try await b.renderFrames(
                    poses: poses,
                    width: dims.width,
                    height: dims.height,
                    basePose: self.camera,
                    convergence: self.convergenceDistance,
                    alignSubject: self.wiggle.style.isTranslation,
                    progress: { done, total in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if case .baking = self.stage {
                                self.stage = .baking(done: done, total: total)
                            }
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                self.frames = rendered
                self.stage = .displaying
            } catch is CancellationError {
                return
            } catch {
                self.stage = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Internals

    private func handleWiggleChange(old: WiggleSettings) {
        // Only geometry changes trigger a rebake. `cycleHz` is playback-only.
        if old.frameCount != wiggle.frameCount
            || old.style != wiggle.style
            || old.frameDistance != wiggle.frameDistance {
            scheduleRebake()
        }
    }

    private func ensureBaker() throws -> FrameBaker {
        if let b = baker { return b }
        let b = try FrameBaker()
        baker = b
        return b
    }

    private func writeSplatPLY(cloud: GaussianCloud, sourceName: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wigglegram", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("\(sourceName)-\(UUID().uuidString.prefix(6)).ply")
        try GaussianIO.savePLY(cloud: cloud, to: url)
        return url
    }

    private func frameCamera(for frustum: SourceFrustum) -> CameraPose {
        // Place the virtual camera exactly at the photo's viewpoint.
        // SHARP's cloud is a per-pixel-ray reconstruction: each splat
        // sits at `((x - W/2) * depth / fOrig, (y - H/2) * depth / fOrig, depth)`
        // in camera-aligned coords. The only pose that reproduces the
        // source photo is eye=origin, forward=+Z, fovY=2*atan(H/(2*fOrig)).
        //
        // `CameraPose` parameterizes the eye as `target - distance * forward`,
        // so we put the target one unit down +Z with distance=1 — that
        // lands the eye on the origin, forward=+Z, which is exactly the
        // photo viewpoint. The exact choice of target distance doesn't
        // matter as long as it's positive; wiggle code derives `forward`
        // from it independently.
        var pose = CameraPose.default
        pose.target = SIMD3<Float>(0, 0, 1)
        pose.distance = 1
        pose.yaw = 0
        pose.pitch = 0
        pose.fovY = frustum.fovY
        return pose
    }
}
