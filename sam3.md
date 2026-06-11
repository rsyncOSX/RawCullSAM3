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

## Makefile Commands

The repository `Makefile` is intentionally small now. It keeps the normal local
workflow focused on building RawCullSAM3 and verifying that the selected SAM3
asset is actually present in the generated `.app` bundle.

The default command is the release build:

```sh
make
```

This is equivalent to:

```sh
make release
```

`make release` runs two steps:

```text
build-release
verify-release-model
```

`build-release` runs Xcode in Release configuration:

```sh
xcodebuild \
  -project RawCullSAM3.xcodeproj \
  -scheme RawCullSAM3 \
  -destination 'platform=macOS' \
  -configuration Release \
  build
```

After the build finishes, `verify-release-model` finds the built
`RawCullSAM3.app` in Xcode DerivedData and checks that the local model was
copied into the app bundle.

The current selected model asset is:

```text
sam3_float16_source.h16c.aimodelc
```

The verification step accepts the layouts RawCull can load at runtime:

```text
RawCullSAM3.app/Contents/Resources/Models/SAM3/sam3_float16_source.h16c.aimodelc
RawCullSAM3.app/Contents/Resources/SAM3/sam3_float16_source.h16c.aimodelc
RawCullSAM3.app/Contents/Resources/sam3_float16_source.h16c.aimodelc
```

For the flattened Xcode resource layout, it also checks for:

```text
RawCullSAM3.app/Contents/Resources/metadata.json
RawCullSAM3.app/Contents/Resources/tokenizer.json
```

or:

```text
RawCullSAM3.app/Contents/Resources/tokenizer/tokenizer.json
```

Use the debug build when you want faster local iteration:

```sh
make debug
```

`make debug` runs:

```text
build-debug
verify-debug-model
```

It builds the app with `-configuration Debug`, then performs the same SAM3
bundle verification against the Debug app in DerivedData.

If you only want to build and skip the model verification, use:

```sh
make build-release
make build-debug
```

If you already built in Xcode and only want to check whether the model landed in
the app bundle, use:

```sh
make verify-release-model
make verify-debug-model
```

The verification targets use this local model path as their source of truth:

```text
RawCullSAM3/Resources/Models/SAM3
```

They require:

```text
RawCullSAM3/Resources/Models/SAM3/metadata.json
RawCullSAM3/Resources/Models/SAM3/sam3_float16_source.h16c.aimodelc
```

To print the latest discovered app bundle path without rebuilding:

```sh
make print-release-app
make print-debug-app
```

To regenerate the local SAM3 bundle from the exporter:

```sh
make sam3-export
```

This runs:

```sh
uv run tools/export_sam3.py --dtype float16 --overwrite
```

The exporter should write the model bundle under:

```text
RawCullSAM3/Resources/Models/SAM3
```

To attempt ahead-of-time Core AI compilation for the source-preserving asset:

```sh
make sam3-compile
```

This runs:

```sh
xcrun coreai-build compile \
  RawCullSAM3/Resources/Models/SAM3/sam3_float16_source.aimodel \
  --platform macOS \
  --architecture h16c \
  --output RawCullSAM3/Resources/Models/SAM3
```

The default architecture is controlled by:

```sh
SAM3_COMPILE_ARCH=h16c
```

Override it when compiling for another Mac architecture:

```sh
make sam3-compile SAM3_COMPILE_ARCH=<architecture>
```

To compile every supported macOS architecture:

```sh
make sam3-compile-all
```

This omits the `--architecture` flag and lets `coreai-build` produce all
supported architecture outputs. The all-architecture output can be much larger
than a single-machine `h16c` build.

After a successful compile, select the asset RawCull should load by updating the
SAM3 bundle metadata:

```sh
make sam3-use-asset
```

By default, this selects:

```text
sam3_float16_source.h16c.aimodelc
```

To select a different compiled or uncompiled asset:

```sh
make sam3-use-asset SAM3_ASSET=<asset-name>
```

Examples:

```sh
make sam3-use-asset SAM3_ASSET=sam3_float16_source.h16c.aimodelc
make sam3-use-asset SAM3_ASSET=sam3_float16.aimodel
```

`sam3-use-asset` runs:

```sh
python3 tools/select_sam3_asset.py $(SAM3_ASSET)
```

That helper updates `RawCullSAM3/Resources/Models/SAM3/metadata.json` so
`assets.main` points at the selected asset.

The `clean` target only removes the repository-local build folder:

```sh
make clean
```

It does not delete Xcode DerivedData and it does not delete the local SAM3
model folder.

If compilation reports that the input is missing source bytecode, keep
`assets.main` pointed at the uncompiled runtime `.aimodel` and rely on Core AI
runtime specialization instead of AOT compilation.

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
