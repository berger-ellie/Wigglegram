import SwiftUI
import MetalKit
import MetalSplatter
import SplatIO
import simd

/// Hosts a MetalSplatter view that renders a single splat PLY from an
/// externally-controlled camera pose. The camera is driven by
/// `CameraPose` which is read every frame in `draw(_:)` — this is what
/// lets the wiggle controller animate the viewpoint.
struct SplatViewer: NSViewRepresentable {
    let plyURL: URL?
    @Binding var camera: CameraPose
    var onCoordinatorReady: ((Coordinator) -> Void)? = nil

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm_srgb
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
        mtkView.delegate = context.coordinator
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60

        if let device = mtkView.device {
            context.coordinator.setup(device: device, view: mtkView)
        }
        onCoordinatorReady?(context.coordinator)
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.cameraProvider = { camera }
        if context.coordinator.currentURL != plyURL {
            context.coordinator.loadSplat(from: plyURL)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        fileprivate var currentURL: URL?
        fileprivate var cameraProvider: () -> CameraPose = { .default }

        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var renderer: SplatRenderer?
        private var depthTexture: MTLTexture?
        private var loadedChunk: ChunkID?
        private var loadTask: Task<Void, Never>?

        func setup(device: MTLDevice, view: MTKView) {
            self.device = device
            self.commandQueue = device.makeCommandQueue()
            do {
                self.renderer = try SplatRenderer(
                    device: device,
                    colorFormat: .bgra8Unorm_srgb,
                    depthFormat: .depth32Float,
                    sampleCount: 1,
                    maxViewCount: 1,
                    maxSimultaneousRenders: 3,
                    highQualityDepth: false,
                    clearColor: MTLClearColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
                )
            } catch {
                print("SplatRenderer init failed: \(error)")
            }
        }

        fileprivate func loadSplat(from url: URL?) {
            loadTask?.cancel()
            currentURL = url
            guard let url, let device, let renderer else {
                if let old = loadedChunk {
                    Task { @MainActor in await renderer?.removeChunk(old) }
                    loadedChunk = nil
                }
                return
            }

            let oldChunk = loadedChunk
            loadedChunk = nil

            loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if let oldChunk {
                    await renderer.removeChunk(oldChunk)
                }
                do {
                    let capturedURL = url
                    let rawPoints = try await Task.detached(priority: .userInitiated) {
                        let reader = try AutodetectSceneReader(capturedURL)
                        return try await reader.readAll()
                    }.value

                    // SHARP produces Y-UP positions; SplatRenderer expects
                    // COLMAP/3DGS Y-DOWN (see SharpSplat SplatViewerView
                    // for the history of this bug). Flip Y once here.
                    let points = rawPoints.map { pt -> SplatPoint in
                        var p = pt
                        p.position = SIMD3<Float>(p.position.x, -p.position.y, p.position.z)
                        return p
                    }

                    guard !Task.isCancelled else { return }
                    let chunk = try await Task.detached(priority: .userInitiated) {
                        try SplatChunk(device: device, from: points)
                    }.value
                    guard !Task.isCancelled else { return }
                    self.loadedChunk = await renderer.addChunk(chunk, sortByLocality: false, enabled: true)
                } catch {
                    print("Splat load failed: \(error)")
                }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            updateDepthTexture(size: size)
        }

        func draw(in view: MTKView) {
            guard let renderer, renderer.isReadyToRender,
                  let commandQueue, let device,
                  let drawable = view.currentDrawable else { return }

            let size = view.drawableSize
            let w = Double(size.width), h = Double(size.height)
            guard w > 0, h > 0 else { return }
            if depthTexture == nil || depthTexture!.width != Int(w) || depthTexture!.height != Int(h) {
                updateDepthTexture(size: size)
            }

            let camera = cameraProvider()
            let aspect = Float(w / h)
            let projection = perspectiveMatrix(fovY: camera.fovY, aspect: aspect, near: 0.01, far: 100)
            let viewMatrix = camera.viewMatrix()

            let viewport = SplatRenderer.ViewportDescriptor(
                viewport: MTLViewport(originX: 0, originY: 0, width: w, height: h, znear: 0, zfar: 1),
                projectionMatrix: projection,
                viewMatrix: viewMatrix,
                screenSize: SIMD2<Int>(x: Int(w), y: Int(h))
            )

            guard let cb = commandQueue.makeCommandBuffer() else { return }
            do {
                _ = try renderer.render(
                    viewports: [viewport],
                    colorTexture: drawable.texture,
                    colorStoreAction: .store,
                    depthTexture: depthTexture,
                    rasterizationRateMap: nil,
                    renderTargetArrayLength: 0,
                    to: cb
                )
            } catch {
                return
            }
            cb.present(drawable)
            cb.commit()
            _ = device
        }

        /// Render one frame to an off-screen texture at a given camera
        /// pose and return a CGImage. Used by the MP4/GIF exporter.
        func renderOffscreen(camera: CameraPose, width: Int, height: Int) async -> CGImage? {
            guard let renderer, renderer.isReadyToRender,
                  let device, let commandQueue else { return nil }

            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb,
                width: width, height: height, mipmapped: false
            )
            texDesc.usage = [.renderTarget, .shaderRead]
            texDesc.storageMode = .managed
            guard let colorTex = device.makeTexture(descriptor: texDesc) else { return nil }

            let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: width, height: height, mipmapped: false
            )
            depthDesc.usage = [.renderTarget]
            depthDesc.storageMode = .private
            guard let depth = device.makeTexture(descriptor: depthDesc) else { return nil }

            let aspect = Float(width) / Float(height)
            let projection = perspectiveMatrix(fovY: camera.fovY, aspect: aspect, near: 0.01, far: 100)
            let viewMatrix = camera.viewMatrix()
            let viewport = SplatRenderer.ViewportDescriptor(
                viewport: MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height), znear: 0, zfar: 1),
                projectionMatrix: projection,
                viewMatrix: viewMatrix,
                screenSize: SIMD2<Int>(x: width, y: height)
            )

            guard let cb = commandQueue.makeCommandBuffer() else { return nil }
            do {
                _ = try renderer.render(
                    viewports: [viewport],
                    colorTexture: colorTex,
                    colorStoreAction: .store,
                    depthTexture: depth,
                    rasterizationRateMap: nil,
                    renderTargetArrayLength: 0,
                    to: cb
                )
            } catch { return nil }

            guard let blit = cb.makeBlitCommandEncoder() else { return nil }
            blit.synchronize(resource: colorTex)
            blit.endEncoding()

            // Don't block the main thread on GPU completion — bridge
            // Metal's callback to async/await.
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                cb.addCompletedHandler { _ in cont.resume() }
                cb.commit()
            }

            let bpr = 4 * width
            var pixels = [UInt8](repeating: 0, count: bpr * height)
            colorTex.getBytes(&pixels, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                    data: &pixels, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bpr,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  let cg = ctx.makeImage()
            else { return nil }
            return cg
        }

        private func updateDepthTexture(size: CGSize) {
            guard let device else { return }
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: max(1, Int(size.width)),
                height: max(1, Int(size.height)),
                mipmapped: false
            )
            desc.usage = [.renderTarget]
            desc.storageMode = .private
            depthTexture = device.makeTexture(descriptor: desc)
        }
    }
}

// MARK: - Camera

struct CameraPose: Equatable {
    var target: SIMD3<Float>
    var distance: Float
    var yaw: Float      // horizontal, radians, 0 = looking down -Z
    var pitch: Float    // vertical, radians
    var fovY: Float

    static let `default` = CameraPose(
        target: .zero, distance: 2.2, yaw: 0, pitch: 0.0, fovY: .pi / 4
    )

    func viewMatrix() -> simd_float4x4 {
        let eye = SIMD3<Float>(
            distance * cos(pitch) * sin(yaw),
            distance * sin(pitch),
            distance * cos(pitch) * cos(yaw)
        ) + target
        return lookAt(eye: eye, center: target, up: SIMD3(0, 1, 0))
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
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return simd_float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
    ))
}
