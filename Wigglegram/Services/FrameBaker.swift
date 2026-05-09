import Foundation
import CoreGraphics
import Metal
import MetalSplatter
import SplatIO
import simd

/// Headless Metal renderer that bakes a set of camera poses into a
/// list of CGImages. Lives outside of any SwiftUI view so the user
/// never sees a live MTKView; playback is done by `FramePlayerView`
/// cycling through the resulting CGImages.
///
/// Ported from the offscreen-render path that used to live on
/// `SplatViewer.Coordinator`.
@MainActor
final class FrameBaker {
    enum Error: LocalizedError {
        case metalUnavailable
        case rendererInitFailed(String)
        case loadFailed(String)
        case renderFailed(frameIndex: Int)
        case notLoaded

        var errorDescription: String? {
            switch self {
            case .metalUnavailable: return "Metal is not available on this device."
            case .rendererInitFailed(let m): return "SplatRenderer init failed: \(m)"
            case .loadFailed(let m): return "Splat load failed: \(m)"
            case .renderFailed(let i): return "Frame \(i) failed to render."
            case .notLoaded: return "No splat loaded."
            }
        }
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderer: SplatRenderer
    private var loadedChunk: ChunkID?
    private var loadedURL: URL?

    /// Reusable offscreen color/depth textures sized to the current
    /// bake. Allocated once per (width, height) and kept for the
    /// lifetime of the bake so phase 1 (pose push) and phase 2 (real
    /// render) don't re-allocate per frame.
    private var cachedColor: MTLTexture?
    private var cachedDepth: MTLTexture?
    private var cachedSize: (Int, Int) = (0, 0)

    init() throws {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            throw Error.metalUnavailable
        }
        self.device = dev
        self.commandQueue = q
        do {
            self.renderer = try SplatRenderer(
                device: dev,
                colorFormat: .bgra8Unorm_srgb,
                depthFormat: .depth32Float,
                sampleCount: 1,
                maxViewCount: 1,
                maxSimultaneousRenders: 3,
                highQualityDepth: false,
                clearColor: MTLClearColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
            )
        } catch {
            throw Error.rendererInitFailed(error.localizedDescription)
        }
    }

    var isLoaded: Bool { loadedChunk != nil }
    var currentURL: URL? { loadedURL }

    // MARK: - Load

    /// Reads the PLY at `url` and uploads a single chunk. Replaces any
    /// previously loaded chunk.
    func loadCloud(plyURL url: URL) async throws {
        if let old = loadedChunk {
            await renderer.removeChunk(old)
            loadedChunk = nil
        }

        let capturedURL = url
        let rawPoints: [SplatPoint]
        do {
            rawPoints = try await Task.detached(priority: .userInitiated) {
                let reader = try AutodetectSceneReader(capturedURL)
                return try await reader.readAll()
            }.value
        } catch {
            throw Error.loadFailed(error.localizedDescription)
        }

        // SHARP's per-pixel-ray output is Y-down in world coords — a
        // pixel at image row 0 (top) unprojects to y = -H/2 · depth /
        // fOrig, which is negative. Our render path uses a standard
        // right-handed `lookAt(up: +Y)`, which puts world +Y at the top
        // of NDC. Without flipping, the image comes out upside-down.
        //
        // We could instead call `lookAt(up: -Y)`, but that re-introduces
        // a horizontal mirror (cross(-Y, +Z) = -X), so the right move
        // is to flip the cloud itself once and keep the standard
        // right-handed view basis everywhere else. Matches what
        // `../SharpSplat/SplatViewer.Coordinator.loadSplat` does.
        var points = rawPoints
        for i in points.indices {
            points[i].position.y = -points[i].position.y
        }

        let chunk: SplatChunk
        do {
            let dev = self.device
            chunk = try await Task.detached(priority: .userInitiated) {
                try SplatChunk(device: dev, from: points)
            }.value
        } catch {
            throw Error.loadFailed(error.localizedDescription)
        }

        // `sortByLocality: true` reorders splats by Morton code so the
        // hot render loop hits cache-coherent memory. Free render-speed
        // win; has nothing to do with the depth sort (that's a separate
        // back-to-front sort inside `SplatSorter`).
        loadedChunk = await renderer.addChunk(chunk, sortByLocality: true, enabled: true)
        loadedURL = url
    }

    func unload() async {
        if let old = loadedChunk {
            await renderer.removeChunk(old)
            loadedChunk = nil
        }
        loadedURL = nil
    }

    // MARK: - Render

    /// Render one pose to a CGImage. Used by `renderFrames` and by
    /// export. All GPU work is awaited via `addCompletedHandler`, never
    /// `waitUntilCompleted` — see the swift-metal-concurrency skill.
    ///
    /// NOTE: This draws using whatever sort is currently most-recent
    /// inside `SplatSorter`. For back-to-front correctness the caller
    /// must first prime the sort for a representative pose via
    /// `primeSortForPose`. Wiggle bakes do this once with the base pose
    /// at the start of `renderFrames` — neighboring wiggle poses share
    /// essentially the same depth ordering as the base (camera shifts
    /// are <12 cm versus typical subject distances of meters), so a
    /// single sort is correct for the whole rig and N× faster than
    /// sorting per pose.
    ///
    /// If you need a fresh sort FOR this specific pose (e.g. single-
    /// frame export from an arbitrary pose), call `primeSortForPose`
    /// with the same pose before `renderFrame`.
    ///
    /// `alignPixelShift`: 2D translation (in pixels) applied to the
    /// decoded image before returning. Used by `renderFrames` to
    /// re-center the convergence-plane subject on lateral rigs (the
    /// traditional wigglegram "keystone" correction). Positive x = shift
    /// image rightward, positive y = shift image downward. Areas outside
    /// the original render are left at the renderer's clear color.
    func renderFrame(
        camera: CameraPose,
        width: Int,
        height: Int,
        alignPixelShift: CGPoint = .zero
    ) async throws -> CGImage {
        guard renderer.isReadyToRender, loadedChunk != nil else { throw Error.notLoaded }

        let (colorTex, depthTex) = ensureCachedTextures(width: width, height: height)

        // Single-phase render: rely on whatever sort is already most-
        // recent. `renderFrames` calls `primeSortForPose` once for the
        // base pose before looping, so all poses in a wiggle bake draw
        // against a correct-enough sort.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            do {
                try encodeAndCommitRender(
                    camera: camera,
                    width: width, height: height,
                    colorTexture: colorTex,
                    depthTexture: depthTex,
                    synchronizeManaged: true,
                    completion: { cont.resume() }
                )
            } catch {
                cont.resume()
            }
        }

        let bpr = 4 * width
        var pixels = [UInt8](repeating: 0, count: bpr * height)
        colorTex.getBytes(&pixels,
                          bytesPerRow: bpr,
                          from: MTLRegionMake2D(0, 0, width, height),
                          mipmapLevel: 0)

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let srcCtx = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bpr,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let srcImage = srcCtx.makeImage()
        else {
            throw Error.renderFailed(frameIndex: -1)
        }

        // No alignment shift requested — hand back the raw render.
        if alignPixelShift == .zero {
            return srcImage
        }

        // Wigglegram keystone correction: translate the rendered image
        // so the convergence-plane subject stays anchored across frames.
        // Areas outside the original render are filled with the same
        // clear colour the renderer uses, so a shift of ±N pixels
        // reveals a matching-tone margin on the opposite side instead
        // of a sharp transparent band. Traditional wigglegram cameras
        // do the same thing mechanically via a slight lateral crop.
        guard let dstCtx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw Error.renderFailed(frameIndex: -1)
        }
        dstCtx.setFillColor(
            red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0
        )
        dstCtx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext is bottom-up, but the intent of `alignPixelShift` is
        // top-down (positive y = shift image downward on the screen).
        // Flip the y sign when placing the source image rect.
        let drawRect = CGRect(
            x: alignPixelShift.x,
            y: -alignPixelShift.y,
            width: CGFloat(width),
            height: CGFloat(height)
        )
        dstCtx.interpolationQuality = .high
        dstCtx.draw(srcImage, in: drawRect)
        guard let shifted = dstCtx.makeImage() else {
            throw Error.renderFailed(frameIndex: -1)
        }
        return shifted
    }

    /// Push `pose` into the sorter and wait for the resulting back-to-
    /// front sort to complete. After this returns, any subsequent
    /// `renderFrame` call (for any nearby pose) will draw against a
    /// valid, up-to-date sorted index buffer.
    ///
    /// Why this exists: `SplatSorter` is a CPU-side back-to-front sort
    /// that runs on a detached task, triggered by `updateCameraPose`.
    /// `SplatRenderer.render` calls `updateCameraPose` internally but
    /// hands back the MOST RECENT valid buffer — which is usually the
    /// *previous* pose's sort. For correctness you must either (a)
    /// wait for the new sort after calling render (what we used to do,
    /// doubling GPU submits), or (b) prime the sort once and trust
    /// that neighboring poses share the same ordering (what we do
    /// now). For wiggle bakes where camera offsets are centimeters
    /// against multi-meter scenes, depth rankings are effectively
    /// identical across all poses, so (b) is both correct and ~N×
    /// faster.
    func primeSortForPose(_ pose: CameraPose, width: Int, height: Int) async throws {
        guard renderer.isReadyToRender, loadedChunk != nil else { throw Error.notLoaded }
        let (colorTex, depthTex) = ensureCachedTextures(width: width, height: height)

        // One render to push the camera pose into the sorter, with an
        // `afterNextSort` handler to wake us when the sort completes.
        // We don't care about the pixels — they're overwritten by the
        // first real `renderFrame` call against the same textures.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumer = OnceResumer(cont: cont)
            renderer.afterNextSort { resumer.resume() }
            do {
                try encodeAndCommitRender(
                    camera: pose,
                    width: width, height: height,
                    colorTexture: colorTex,
                    depthTexture: depthTex,
                    synchronizeManaged: false,
                    completion: nil
                )
            } catch {
                resumer.resume()
            }
        }
    }

    // MARK: - Render helpers

    /// Allocate (or reuse) the offscreen color + depth textures for the
    /// current bake size. Invalidates the cache if the size changed.
    private func ensureCachedTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture) {
        if cachedSize == (width, height), let c = cachedColor, let d = cachedDepth {
            return (c, d)
        }

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, mipmapped: false
        )
        colorDesc.usage = [.renderTarget, .shaderRead]
        colorDesc.storageMode = .managed

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: width, height: height, mipmapped: false
        )
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private

        guard let c = device.makeTexture(descriptor: colorDesc),
              let d = device.makeTexture(descriptor: depthDesc) else {
            fatalError("Failed to allocate offscreen textures at \(width)x\(height)")
        }
        cachedColor = c
        cachedDepth = d
        cachedSize = (width, height)
        return (c, d)
    }

    /// Encode a single render and commit. If `completion` is non-nil,
    /// the command buffer's completion handler will invoke it.
    /// `synchronizeManaged` inserts a blit sync for managed-storage
    /// readback.
    private func encodeAndCommitRender(
        camera: CameraPose,
        width: Int,
        height: Int,
        colorTexture: MTLTexture,
        depthTexture: MTLTexture,
        synchronizeManaged: Bool,
        completion: (@Sendable () -> Void)?
    ) throws {
        guard let cb = commandQueue.makeCommandBuffer() else {
            throw Error.renderFailed(frameIndex: -1)
        }

        let aspect = Float(width) / Float(height)
        let projection = perspectiveMatrix(fovY: camera.fovY, aspect: aspect, near: 0.01, far: 100)
        let viewMatrix = camera.viewMatrix()
        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(
                originX: 0, originY: 0,
                width: Double(width), height: Double(height),
                znear: 0, zfar: 1
            ),
            projectionMatrix: projection,
            viewMatrix: viewMatrix,
            screenSize: SIMD2<Int>(x: width, y: height)
        )

        do {
            _ = try renderer.render(
                viewports: [viewport],
                colorTexture: colorTexture,
                colorStoreAction: .store,
                depthTexture: depthTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                sortTimeout: 2.0,
                to: cb
            )
        } catch {
            throw Error.renderFailed(frameIndex: -1)
        }

        if synchronizeManaged {
            guard let blit = cb.makeBlitCommandEncoder() else {
                throw Error.renderFailed(frameIndex: -1)
            }
            blit.synchronize(resource: colorTexture)
            blit.endEncoding()
        }

        if let completion {
            cb.addCompletedHandler { _ in completion() }
        }
        cb.commit()
    }

    /// Render an ordered batch of poses. Aborts if the parent task is
    /// cancelled.
    ///
    /// `basePose` is the framing pose the wiggle rig is centered on
    /// (i.e. `AppState.camera`). When `alignSubject` is true, each
    /// rendered frame is translated in pixel space so the world point
    /// at `convergence` distance along `basePose.forward` stays
    /// anchored at the image center — the canonical wigglegram keystone
    /// correction that makes the subject "stick" while nearer/farther
    /// content parallaxes around it. Ignored for rotate-style rigs
    /// (they already converge geometrically).
    func renderFrames(
        poses: [CameraPose],
        width: Int,
        height: Int,
        basePose: CameraPose? = nil,
        convergence: Float = 1,
        alignSubject: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [CGImage] {
        guard renderer.isReadyToRender, loadedChunk != nil else { throw Error.notLoaded }
        var out: [CGImage] = []
        out.reserveCapacity(poses.count)

        // Pixel-space shift for a 1 m world-space camera offset at this
        // bake's FoV + convergence. Multiplying by the per-pose camera
        // delta (projected onto base.right / base.up) yields the pixel
        // translation that re-centers the convergence-plane subject.
        //
        // Derivation: a world point at `basePose.eye + convergence *
        // basePose.forward`, viewed from a camera shifted by Δ along
        // `basePose.right`, projects to NDC.x = -Δ · fx / (c * W/2).
        // In pixels from center that's `-Δ · fx / c`, with
        // `fx = fy = H / (2·tan(fovY/2))` for the square pixels we
        // render at. We negate the sign when translating the image to
        // counteract the subject's apparent motion, so the final
        // coefficient is `+fy / c`.
        let focalPx = Float(height) / (2 * tan((basePose?.fovY ?? .pi / 4) * 0.5))
        let pxPerMeter: Float = alignSubject && convergence > 1e-4
            ? focalPx / convergence
            : 0

        // Prime the back-to-front sort against the rig-centered pose
        // before the first real render. Wiggle rigs shift the camera by
        // at most a few centimeters around `basePose`; sort order is
        // depth-based, so a sort valid for the base pose is also valid
        // (up to negligible swaps between nearly-coplanar splats) for
        // every wiggle pose. Doing this once and reusing it across N
        // poses is the difference between a 3-second bake and a
        // near-instant one.
        let sortPose = basePose ?? poses.first ?? CameraPose.default
        let tSort = Date()
        try await primeSortForPose(sortPose, width: width, height: height)
        NSLog("[Wigglegram] bake prime-sort %.3fs", -tSort.timeIntervalSinceNow)

        let t0 = Date()
        for (i, pose) in poses.enumerated() {
            try Task.checkCancellation()
            let frameStart = Date()

            let shift = Self.alignmentShift(
                pose: pose,
                base: basePose,
                pxPerMeter: pxPerMeter
            )

            let cg = try await renderFrame(
                camera: pose,
                width: width, height: height,
                alignPixelShift: shift
            )
            let dt = -frameStart.timeIntervalSinceNow
            NSLog("[Wigglegram] bake frame %d/%d %.3fs shift=(%.1f, %.1f)",
                  i + 1, poses.count, dt,
                  Double(shift.x), Double(shift.y))
            out.append(cg)
            progress?(i + 1, poses.count)
        }
        NSLog("[Wigglegram] bake total %.3fs (%d frames)", -t0.timeIntervalSinceNow, poses.count)
        return out
    }

    /// Pixel-space translation needed to re-center the convergence
    /// subject for `pose`, assuming `base` is the rig-centered
    /// reference. Returns `.zero` when alignment is disabled
    /// (`pxPerMeter == 0`), when no base is provided, or when the pose
    /// matches the base.
    private static func alignmentShift(
        pose: CameraPose,
        base: CameraPose?,
        pxPerMeter: Float
    ) -> CGPoint {
        guard pxPerMeter != 0, let base else { return .zero }
        let delta = pose.eye - base.eye
        let dx = simd.dot(delta, base.right)
        let dy = simd.dot(delta, base.up)
        // +dx in world → subject drifts left in image → shift image
        // right to compensate. +dy in world → subject drifts down in
        // image (CGContext/screen y points down) → shift image down.
        // `alignPixelShift` is top-down (positive y = downward).
        return CGPoint(
            x: CGFloat(dx * pxPerMeter),
            y: CGFloat(-dy * pxPerMeter)
        )
    }
}

/// Tiny helper so `afterNextSort`'s `@Sendable () -> Void` handler can
/// safely resume a continuation even if MetalSplatter ever fires it
/// more than once. Continuations must be resumed exactly once.
nonisolated private final class OnceResumer: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?

    nonisolated init(cont: CheckedContinuation<Void, Never>) {
        self.cont = cont
    }

    nonisolated func resume() {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume()
    }
}
