# Wigglegram — Status

Snapshot for the next agent opening `/Users/ellie/xcode/Wigglegram` as a fresh Cursor workspace.

Last updated: 2026-05-09 (post correctness pass + perf/mirror fix — right-handed lookAt, pixel-shift subject alignment on lateral rigs, aspect-aware bake size).

## TL;DR

A macOS SwiftUI app that turns a single photo into an analog-style wiggle-gram.

- Drop photo → Apple's SHARP CoreML model → 3D Gaussian splat → offscreen Metal `FrameBaker` renders N discrete camera poses → `FramePlayerView` cycles the CGImages at a user-chosen fps with ping-pong → export MP4/GIF from the cached frames.
- No live Metal view on screen anymore. Sliders that affect geometry debounce-rebake; `WIGGLE SPEED` is playback-only and never triggers a rebake.
- Built and launched cleanly on macOS 15+/Xcode 26. `xcodebuild -scheme Wigglegram build` → BUILD SUCCEEDED. The app window comes up, SHARP mmaps, no runtime errors.
- UI matches the "SHARP WIGGLES" Figma mock: black canvas, display title, rainbow chip, big rounded-corner framed preview, monospaced labeled sliders, big red EXPORT button, custom 4-button STYLE toolbar.
- **Still not driven end-to-end by a human.** Launching + idling works; dropping a real photo, confirming the scene is front-facing, and exporting an MP4 is the next manual step — see "Human validation TODO" below.

## Why this project exists

Spawned from the sibling `../SharpSplat` project, which is the full multi-view Gaussian-splat pipeline. Wigglegram is intentionally much smaller — it exists to exercise **just** the SHARP monocular → splat → animated-camera path for a quick, consumer-facing feature.

## Model situation

- File: `Wigglegram/Resources/sharp.mlpackage` (~2.5 GB).
- Source: `huggingface.co/pearsonkyle/Sharp-coreml` (CoreML conversion of Apple's SHARP).
- The model **is on disk locally** but **is gitignored** (see `.gitignore`). The Xcode project references the path, so Xcode compiles it into `sharp.mlmodelc` inside the `.app` at build time.
- If you clone this repo fresh and the file is missing, re-download:

  ```bash
  uv run --with huggingface_hub python3 -c "
  from huggingface_hub import snapshot_download
  snapshot_download(
      repo_id='pearsonkyle/Sharp-coreml',
      allow_patterns=['sharp.mlpackage/*', 'sharp.mlpackage/**/*'],
      local_dir='Wigglegram/Resources',
  )
  "
  ```

- Runtime lookup order in `SHARPInferenceService.resolveModelURL`:
  1. `Bundle.main` → `sharp.mlmodelc` (Xcode-compiled, fast load).
  2. `Bundle.main` → `sharp.mlpackage`.
  3. `~/Library/Application Support/Wigglegram/models/sharp.{mlmodelc,mlpackage,mlmodel}`.
- If none of those exist, the UI shows an actionable error — it does not silently fail.

## How to build / run

```bash
open Wigglegram.xcodeproj
# then ⌘R in Xcode
```

Command-line:

```bash
xcodebuild -project Wigglegram.xcodeproj -scheme Wigglegram \
  -configuration Debug -destination 'platform=macOS' \
  -skipPackagePluginValidation -skipMacroValidation build
```

First build pulls the `MetalSplatter` SPM package from GitHub; subsequent builds are cached.

## Architecture

```
Wigglegram/
├── App/
│   ├── WigglegramApp.swift      @main, AppDelegate, WindowGroup wiring
│   └── AppState.swift            @MainActor @Observable — single source of truth; owns FrameBaker + frames cache
├── Models/
│   ├── CameraPose.swift          CameraPose struct + perspectiveMatrix + lookAt (extracted from old SplatViewer)
│   ├── GaussianCloud.swift       Positions/scales/rotations/colors/opacities + bbox + medianDepth + SourceFrustum
│   ├── WiggleCamera.swift        `poses(base:settings:convergence:)` → discrete [CameraPose] for the current style (shift = parallel rig, rotate = toe-in)
│   └── WiggleSettings.swift      Style enum (shift/rotate × h/v) + frameDistance (single cm baseline for all styles) + frameCount + cycleHz (wiggle-rate in Hz; playbackFps derived from cycleHz × pingPongSteps)
├── Services/
│   ├── FrameBaker.swift             Headless MTLDevice + SplatRenderer + SplatChunk; loadCloud + renderFrames async
│   ├── SHARPInferenceService.swift  CoreML load, preprocess, predict, extract, unproject
│   └── GaussianIO.swift             Binary 3DGS PLY writer (linearToSRGB, log scales, inverseSigmoid opacity)
├── Views/
│   ├── ContentView.swift         Figma-style layout: header, framed FramePlayerView, status strip, slider column, STYLE row, EXPORT
│   ├── FramePlayerView.swift     Cycles [CGImage] at fps with ping-pong; falls back to sourceImage while baking
│   ├── Theme.swift               Colors, fonts, corner radii, RainbowChip view
│   └── WiggleSliderRow.swift     Reusable monospaced label + slider + value row
├── Export/
│   └── WiggleExporter.swift      MP4 via AVAssetWriter, GIF via CGImageDestination; takes [CGImage] directly, ping-pong expanded
└── Resources/
    └── sharp.mlpackage           gitignored; the actual weights
```

### Data flow

1. `ContentView.handleDrop` / `pickPhoto` → `AppState.processImage(at:)`.
2. `processImage` immediately decodes the photo into `sourceImage` so `FramePlayerView` has something to show while the rest of the pipeline runs. If SHARP isn't loaded yet, stage flips to `.pendingImage(url)` and `warmUpModel` picks it up when it finishes.
3. `SHARPInferenceService.runInference`:
   - decodes the photo, resizes to 1536×1536, packs a `[1, 3, H, W]` float32 `MLMultiArray`,
   - runs `MLModel.prediction(from:)` with `image` + `disparity_factor` inputs,
   - pulls the five output arrays (`mean_vectors_3d_positions`, `singular_values_scales`, `quaternions_rotations`, `colors_rgb_linear`, `opacities_alpha_channel`) via a fast float32 stride path (matches SharpSplat's proven fast path),
   - unprojects into the SharpSplat v4 Y-up metric frame,
   - **returns `(GaussianCloud, SourceFrustum)`** so downstream code knows the photo's original width/height/focal.
4. `AppState.writeSplatPLY` dumps the cloud to `tmp/Wigglegram/<name>-<uuid>.ply` in standard 3DGS format.
5. `FrameBaker.loadCloud(plyURL:)` reads it back through `SplatIO.AutodetectSceneReader` and adds it as a chunk. No Y-flip, no X-flip — `CameraPose.lookAt` is right-handed (`s = cross(up, f)`) which matches SHARP's Y-up per-pixel-ray convention directly. The previous codepath flipped Y in the cloud to compensate for a left-handed `lookAt`; fixing `lookAt` was the real fix.
6. `AppState.frameCamera(for: frustum)` places the virtual camera at the source photo's viewpoint: eye at origin, forward=+Z, `fovY = 2*atan(H / (2*fOrig))`. This is the only pose that reproduces SHARP's per-pixel-ray reconstruction without showing the edges of the splat.
7. `AppState.rebakeFrames()` builds poses via `WiggleCamera.poses(base:settings:convergence:)` and calls `FrameBaker.renderFrames(poses:width:height:basePose:convergence:alignSubject:)`. Preview bake dimensions come from `AppState.bakeDimensions`: shortest axis is 768, the other axis preserves the source frustum aspect (clamped to 2:1 so panoramas don't blow out the texture). Baking into the source aspect is what makes the splat fill the frame instead of leaking black borders.
8. **Depth-sort correctness**: `FrameBaker.renderFrame` wraps each pose in a two-phase render: the first render pushes the new view matrix into `SplatSorter` via `updateCameraPose` (called unconditionally inside `SplatRenderer.render`), and we register `renderer.afterNextSort` beforehand via a `OnceResumer` so we can `await` the first sort that completes AFTER our submit. Then a second render into the same cached color/depth textures draws against the freshly sorted index buffer. Without this, `SplatRenderer.render` hands back the previous sort's indices, so background splats draw over foreground ones until the next parameter change drains the queue. Both renders reuse cached textures (one allocation per bake size, not per frame) so the perf cost is ~2 Metal submits per pose, not 2 allocations. `[Wigglegram] bake frame N/M Xs shift=(dx, dy)` + total is logged per bake.
9. **Subject alignment (lateral rigs only)**: after each frame renders, `FrameBaker` translates the decoded CGImage in pixel space by `(+Δx · f / c, -Δy · f / c)`, where `Δ = pose.eye - basePose.eye` projected onto `basePose.right`/`basePose.up`, `f = H/(2·tan(fovY/2))` is the rendered focal length in pixels, and `c = convergenceDistance` is the median splat depth. This is the classic wigglegram keystone correction — it re-centers the convergence-plane subject so the animation reads as "subject anchored, background parallaxes around it" rather than "whole scene slides left/right." Rotate-style rigs already converge geometrically, so `alignSubject` is gated by `wiggle.style.isTranslation`. Areas revealed by the shift are filled with the same `(0.04, 0.04, 0.06)` clear colour the renderer uses, so there are no sharp transparent edges.
10. Any slider that affects geometry (`frameDistance`, `frameCount`, `style`) goes through `AppState.scheduleRebake()`, which debounces 250 ms and cancels the in-flight bake. `fps` only restarts the playback timer.
11. Export: `WiggleExporter.export(frames:fps:format:to:)` takes the cached `[CGImage]` directly, expands them into a ping-pong sequence, and writes MP4 or GIF. No re-rendering at export time.

### Concurrency conventions (match `../SharpSplat`)

- `AppState` is `@MainActor`. Long work is `Task.detached(priority: .userInitiated)`.
- `SHARPInferenceService` is `nonisolated final class @unchecked Sendable` with an `NSLock` around the model ref.
- Offscreen Metal renders **never block the main thread on GPU** — they bridge `addCompletedHandler` into a `CheckedContinuation`. Don't replace that with `cb.waitUntilCompleted()`. See the `swift-metal-concurrency` skill for why.

## Xcode project notes

- Single app target, no test targets.
- Uses **PBXFileSystemSynchronizedRootGroup** — adding/removing files under `Wigglegram/` doesn't require editing `project.pbxproj`. Just drop the file on disk.
- SPM: `https://github.com/scier/MetalSplatter.git` at `1.0.1+`; products `MetalSplatter`, `SplatIO`, `PLYIO`.
- Deployment target: `macOS 15.0` (MetalSplatter requires 15; we started at 14 and hit a module-version error — do not drop back).
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. `nonisolated` annotations on `GaussianCloud`, `SHARPInferenceService`, `GaussianIO` are load-bearing under this default.
- Sandbox on; `ENABLE_USER_SELECTED_FILES = readwrite`; hardened runtime on.
- Bundle id: `BERGER.Wigglegram`.

## Known quirks / open work

- **The correctness pass still needs human eyes.** Code compiles, app launches, no startup crash — but a few things can only be validated by dropping a real photo:
  - The two-phase sort sync doubles per-pose GPU submits. Textures are cached per bake size so allocation isn't the bottleneck. If bake feels slow on very large splats, the `afterNextSort` continuation wait is the first place to profile. Parallel rendering across cores isn't used (MetalSplatter's internal state isn't safe for concurrent poses), but we could try grouping the sort-wait across multiple frames if needed.
  - `FrameBaker.loadCloud` does **not** flip Y. Axes are correct because `CameraPose.lookAt` is right-handed. If a future regression renders upside-down or mirrored, fix `lookAt` — don't paper over it in the cloud.
  - Rotation-style convergence and the lateral pixel-shift both use `GaussianCloud.medianDepth` (median of `abs(z)`). SHARP occasionally produces big outlier splats; if the pivot looks wrong, consider a trimmed mean or an interquartile median.
  - The disparity factor math in `runInference` matches SharpSplat but assumes unknown EXIF focal. The `focalLengthPx` parameter is always called with `nil` from `AppState`; if wiggle feels off, this is the first thing to question. A diagnostic `NSLog` of the disparity factor + input size + frustum is emitted per photo — grep Console.app for `[SHARP]` / `[Wigglegram]`.
  - Export render size is hardcoded to whatever was baked for preview (768²). If that feels small, bump `AppState.bakeSize` to 1024 and accept the extra latency, or add a separate "bake at export res" pass.
- **2.5 GB bundle.** Bundling works locally but is unwieldy. If shipping, switch to first-run download into `Application Support/Wigglegram/models/` — the resolver already supports it.
- **No app icon / asset catalog.** SwiftUI `@main` works without one, but the Dock icon is generic.
- **No test target.** Intentional for v1.
- **SwiftData unused.** `AppState` holds everything in memory — a wigglegram session is disposable.

## UI (post Figma redesign, post prerender rewrite)

Matches the spirit of the "SHARP WIGGLES" mock at `figma.com/design/6RH7x8BYrqTnYNrS5xqIxk`:

- Solid `#080808` canvas, hidden title bar, fixed layout (not `HSplitView`).
- Display title top-left, `RainbowChip` top-right (drawn in SwiftUI, no asset).
- Rounded-corner framed preview (28pt radius, 4pt white stroke) on the left; `FramePlayerView` renders inside the frame. Before SHARP runs, the dropped photo shows as a fallback; once frames are baked, it cycles through them in ping-pong.
- A thin status strip *below* the frame shows stage text ("RUNNING SHARP…", "BAKING FRAMES 2/4…", "WAITING FOR MODEL…") instead of blocking the preview with a modal overlay.
- Slider column on the right: FRAME DISTANCE (single slider, 0.5-12 cm, applies to all styles) / FRAME COUNT (2-15) / WIGGLE SPEED (2-30 fps). No PITCH, no AMPLITUDE.
- STYLE row is now a custom 4-button toolbar with SF Symbol glyphs + uppercase labels: H SHIFT, V SHIFT, H ROTATE, V ROTATE. Renders legibly on `#080808`, unlike the segmented picker.
- Big red EXPORT capsule button calls `exportTapped(.mp4)`; right-click → MP4 or GIF. Disabled until frames are baked.
- Fonts walk a chain ending in system fallbacks: `BN Hightide → Futura-Bold → AvenirNext-Heavy → system .black` for display; `OT Bulb Monoline → IBMPlexMono-Medium → Menlo-Bold → system .monospaced` for labels. Swap in a licensed face by installing it on the system — no code change needed.

## Human validation TODO

One thing only, and it has to happen on a machine where someone can actually drag a file:

1. `⌘R` in Xcode (or `open /Users/ellie/Library/Developer/Xcode/DerivedData/Wigglegram-*/Build/Products/Debug/Wigglegram.app`). The dropzone should appear immediately — SHARP loads in the background ("LOADING SHARP…" in the status strip).
2. Drop one JPEG/HEIC into the framed preview **while the model is still loading**. The photo itself should appear in the frame right away; status strip flips to "WAITING FOR MODEL…". When SHARP finishes loading, processing should start automatically.
3. Watch Console.app filtered on `Wigglegram` — expect one `[SHARP] input=WxH focalPx=… disparityFactor=…` line and one `[Wigglegram] cloud count=… medianDepth=… frustum=WxH fOrig=… fovY=…deg` line.
4. **Base-frame sanity.** Before touching any slider, the preview's base frame should look like the original photo — right-side-up, not mirrored, not a floating splat with visible edges. If it's upside-down or mirrored, `CameraPose.lookAt` regressed back to a left-handed cross product. If you see black edges, the source frustum's aspect ratio diverged from what `AppState.bakeDimensions` is producing.
5. **Depth-sort sanity.** Cycle through all 4 STYLE buttons. On every frame of every style, confirm no background element draws in front of a foreground element. If you still see it, the `afterNextSort` continuation isn't firing — check `SplatSorter` wiring in the MetalSplatter version pinned in SPM.
6. **Subject alignment (H-SHIFT / V-SHIFT).** In H-SHIFT mode, the central subject (around the median depth) should stay roughly pinned frame-to-frame, with foreground closer than subject drifting one way and background drifting the other — textbook parallax around an anchor. If the whole scene slides uniformly, the pixel shift in `FrameBaker.renderFrames` isn't being applied (check `alignSubject`/`basePose` plumbing from `AppState`). Rotate modes should NOT apply the shift (they already converge geometrically).
7. **Frame distance feels right.** At 3 cm in H-SHIFT the parallax should read as a subtle, camera-sized baseline. Switch to H-ROTATE at the same 3 cm — the scene should pivot around the subject (median-depth point), not around the camera, and the overall parallax magnitude on the near subject should be similar to the shift mode. Vertical counterparts behave analogously.
8. At FRAME DISTANCE = 0.5 cm the wiggle should be tiny but still present; at 12 cm it should be dramatic without exposing splat edges.
9. Click the red EXPORT button, save an MP4, open it in QuickTime. It should match what's on screen (same pose ordering, same ping-pong, same framing — the pixel-shift alignment bakes in, so it's already baked into exports).

## Sibling project: `../SharpSplat`

Much bigger multi-view reconstruction app. Living source of truth for:

- The original `SHARPInferenceService` (see `../SharpSplat/SharpSplat/Services/SHARPInferenceService.swift`) — has an EnumeratedShapes neural-engine path and per-project caching we intentionally dropped here.
- `GaussianCloud` / `GaussianIO` (full version with `SimilarityTransform`, decimation, metadata, load path).
- `SplatViewerView` — the multi-cloud version the `SplatViewer` here is trimmed from. The cache-invariant comments in the original are worth reading before touching `loadSplat`.
- `.cursor/design/new-app.md` — explicitly states the SharpSplat team pivoted **away** from SHARP-monocular for their multi-view use case. Wigglegram is a single-image app, so that criticism doesn't apply.

When in doubt, diff against that repo — most of this code is ported directly.

## Git

- Branch: `main`.
- One commit so far: "Initial Wigglegram: drop a photo, get an analog-style wiggle-gram."
- No remote configured.
