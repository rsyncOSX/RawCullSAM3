# RawCullSAM3

RawCullSAM3 is a macOS photo culling app that uses Apple Core AI SAM3 (Segment Anything Model 3) for AI-powered subject segmentation. It integrates with the promptable SAM3 path introduced in WWDC26, enabling fast and accurate subject masking directly from the camera roll.

## Requirements

- Xcode 27 or newer with Core AI tooling
- macOS 27 deployment target
- Apple Core AI Models Swift package linked to the app target (`CoreAISegmentation` / `CoreAIImageSegmenter`)

## Architecture Overview

```text
ZoomOverlayView
  -> SubjectSegmentationActor
  -> CoreAISAM3Provider
  -> CoreAIImageSegmenter.ImageSegmenter
  -> SubjectMaskCache
```

The UI exposes a prompt picker. `SubjectSegmentationPrompt` maps user choices to text prompts passed to Core AI SAM3.

Masks are cached on disk via `SAM3MaskDiskCache` under:

```text
~/Library/Caches/no.blogspot.RawCull/SAM3Masks/
```

A bundled helper process (`RawCullSAM3MaskBuilder`) can pre-generate masks for an entire catalog, writing results into the same cache. RawCull then reads cached masks without re-running inference during browsing.

## SAM3 Model Setup

The SAM3 model is not bundled with the app. It lives outside the signed app bundle at:

```text
$(HOME)/Library/Containers/no.blogspot.RawCullSAM3/Data/Library/Application Support/RawCullSAM3/Models/SAM3
```

The model bundle must contain:
- `metadata.json` (with `assets.main` pointing at the active model file)
- `sam3_float16.aimodel` (or another compiled asset)
- `tokenizer/tokenizer.json` and `tokenizer/tokenizer_config.json`

### Export the model

The exporter downloads `facebook/sam3` from Hugging Face and converts it to Core AI format. If Hugging Face requires authentication, log in first:

```sh
huggingface-cli login
# or pass the token inline:
HF_TOKEN=hf_your_token_here make sam3-export
```

Then export:

```sh
make sam3-export
```

### Install the model for local use

```sh
make install-sam3-model
```

This copies `RawCullSAM3/Resources/Models/SAM3` to the Application Support location above.

## Building

| Command | Description |
|---|---|
| `make` / `make release` | Release build + model verification |
| `make debug` | Debug build + model verification |
| `make build-release` | Release build only (skip verification) |
| `make build-debug` | Debug build only (skip verification) |
| `make verify-model` | Verify external model is installed |
| `make clean` | Remove local build folder |

To print the built app path without rebuilding:

```sh
make print-release-app
make print-debug-app
```

## Optional: Ahead-of-Time Compilation

Core AI specialises the `.aimodel` on first load, so AOT compilation is optional. To compile manually:

```sh
make sam3-compile                          # default h16c architecture
make sam3-compile SAM3_COMPILE_ARCH=<arch> # specific architecture
make sam3-compile-all                      # all supported architectures
make sam3-compile-gpu                      # GPU-preferred asset
```

After compilation, select the active asset:

```sh
make sam3-use-asset SAM3_ASSET=sam3_float16_source.h16c.aimodelc
make sam3-use-asset SAM3_ASSET=sam3_float16.aimodel  # revert to runtime model
```

## What's Next

With catalog-wide mask generation in place, the focus shifts to turning cached masks into culling signals without re-running SAM3:

- **Subject quality badges** — green/amber/red badge on thumbnails showing mask confidence and coverage
- **Subject geometry filters** — filter by subject size, clipping, or off-center position
- **Subject-weighted sharpness scoring** — use the SAM3 mask as the primary sharpness region instead of saliency heuristics
- **Best-in-burst by subject sharpness** — automatically suggest the sharpest, best-framed frame in a burst
- **Bounding box export** — write subject bounding boxes to JSON sidecars for downstream tools

## Notes

- Do **not** copy SAM3 model files into the app bundle (`RawCullSAM3.app/Contents/Resources`). This invalidates the app signature.
- Debug builds may fall back to a bundled model directory for local development; release and App Store builds must not include model files.
- `ExternalSAM3Provider` remains in the project for explicit debug/test injection.
