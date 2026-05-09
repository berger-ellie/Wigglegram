# Wigglegram

Turn any photo into an analog-style wiggle-gram, on-device, on macOS.

## What it does

1. You drop a photo onto the window.
2. Apple's [SHARP](https://github.com/apple/ml-sharp) monocular model (via a CoreML conversion by [pearsonkyle/Sharp-coreml](https://huggingface.co/pearsonkyle/Sharp-coreml)) turns it into a 3D Gaussian splat in one forward pass.
3. A virtual camera wiggles left/right around the subject while [MetalSplatter](https://github.com/scier/MetalSplatter) renders the splat in real time.
4. Tune amplitude, frame count, FPS, and loop style; export as MP4 or animated GIF.

Runs entirely on-device on Apple Silicon.

## Getting the CoreML weights

The SHARP CoreML package is ~2.7 GB and is **not** checked into git. Grab it once:

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

The app resolves the model in this order:

1. `Wigglegram.app/Contents/Resources/sharp.mlpackage` (bundled at build time, preferred).
2. `~/Library/Application Support/Wigglegram/models/sharp.mlpackage` (user override).

If neither exists the UI shows an actionable error rather than silently doing nothing.

## Credit

- **SHARP**: Apple ML. [arxiv.org/abs/2512.10685](https://arxiv.org/abs/2512.10685), [apple.github.io/ml-sharp](https://apple.github.io/ml-sharp), [github.com/apple/ml-sharp](https://github.com/apple/ml-sharp).
- **CoreML conversion**: [pearsonkyle/Sharp-coreml](https://huggingface.co/pearsonkyle/Sharp-coreml).
- **Rendering**: [scier/MetalSplatter](https://github.com/scier/MetalSplatter) (MIT).
- **Swift SHARP service + GaussianIO**: ported from the sibling `SharpSplat` project in this workspace.

## Project structure

```
Wigglegram/
├── Wigglegram/                         # Swift sources
│   ├── App/                            # @main, SwiftUI root
│   ├── Services/                       # SHARPInferenceService, GaussianIO
│   ├── Models/                         # GaussianCloud, SimilarityTransform
│   ├── Views/                          # SplatViewer, WiggleControls
│   └── Export/                         # MP4/GIF frame writers
├── Wigglegram/Resources/sharp.mlpackage   # downloaded separately (gitignored or LFS)
└── Wigglegram.xcodeproj
```
