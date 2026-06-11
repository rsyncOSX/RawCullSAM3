# Core AI SAM3 Integration Notes

find ~/Library/Developer/Xcode/DerivedData -path '*RawCullSAM3.app/Contents/Resources*SAM3*' | head

RawCullSAM3 now targets the promptable Apple Core AI SAM3 path described in
WWDC26 session 326, rather than the earlier Vision foreground-mask fallback.

## Runtime Shape

The app keeps its existing subject segmentation boundary:

```text
ZoomOverlayView
  -> SubjectSegmentationActor
  -> CoreAISAM3Provider
  -> CoreAIImageSegmenter.ImageSegmenter
  -> SubjectMaskCache
  -> overlay and future subject sharpness scoring
```

The UI continues to expose RawCull's prompt picker. `SubjectSegmentationPrompt`
maps those choices to the text prompts passed to Core AI SAM3.

## Model Resource

For the first implementation, RawCull uses a local bundled model asset. Place
the Core AI model bundle under `RawCullSAM3/Resources/Models/SAM3` so it is
copied into the app bundle's `Models` subdirectory. The Swift runtime package
expects a model-bundle directory containing `metadata.json`, `assets.main`, and
SAM3 tokenizer assets.

For migration/dev convenience, RawCull also checks for `SAM3.aimodelc` and
`SAM3.aimodel`, but the Apple package's high-level `ImageSegmenter` initializer
loads the model-bundle directory shape. Keep the exported `.aimodel` name in
sync with the bundle's `metadata.json` `assets.main` value.

RawCull searches both `Contents/Resources/Models` and the app bundle resource
root. If Xcode flattens the model contents when the real asset is added, add the
SAM3 model directory as a folder reference/resource so the bundle layout remains
intact.

The bundled `.aimodel` can be used directly. Core AI will specialize it on
first load, so ahead-of-time compilation is optional.

To regenerate the bundle with a source asset for AOT experiments:

```sh
uv run tools/export_sam3.py --dtype float16 --overwrite
```

Compile the source asset, not the optimized runtime asset:

```sh
make sam3-compile
```

If compilation succeeds, update `RawCullSAM3/Resources/Models/SAM3/metadata.json`
so `assets.main` points to the generated `.aimodelc`. If compilation reports
that the input is missing source bytecode, keep `assets.main` pointed at the
uncompiled `sam3_float16.aimodel` and rely on runtime specialization.

Use the selector helper to switch assets:

```sh
make sam3-use-asset ASSET=<generated-file>.aimodelc
```

`make sam3-compile` defaults to `SAM3_COMPILE_ARCH=h16c`, which matches the
local Apple M4 development machine. Override it for another Mac, or run
`make sam3-compile-all` for every supported macOS architecture. The all-arch
build is large.

First model load can still specialize on the device. The provider lazy-loads
and reuses one `ImageSegmenter` instance so subsequent masks in the same app
session do not reload the model.

## Project Requirements

- Xcode 27 or newer with Core AI tooling.
- macOS 27 deployment target.
- Apple Core AI Models Swift package linked to the app target.
- `CoreAISegmentation` package product, imported from Swift as
  `CoreAIImageSegmenter`.

## Fallback

`ExternalSAM3Provider` remains in the project for explicit debug/test injection,
but `SubjectSegmentationActor()` defaults to the local Core AI SAM3 provider.
