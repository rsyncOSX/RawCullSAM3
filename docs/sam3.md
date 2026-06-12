# Core AI SAM3 Integration Notes

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

RawCull treats SAM3 as an external runtime model. Generate or stage the Core AI
model bundle under `RawCullSAM3/Resources/Models/SAM3`, then install it for app
runtime use at:

```text
~/Library/Application Support/RawCull/Models/SAM3
```

The Swift runtime package expects a model-bundle directory containing
`metadata.json`, `assets.main`, and SAM3 tokenizer assets.

For migration/dev convenience, RawCull also checks for `SAM3.aimodelc` and
`SAM3.aimodel`, but the Apple package's high-level `ImageSegmenter` initializer
loads the model-bundle directory shape. Keep the exported `.aimodel` name in
sync with the bundle's `metadata.json` `assets.main` value.

RawCull checks the Application Support install location first. Debug builds may
also fall back to a bundled model directory for local development, but release
and App Store builds should not include the SAM3 model files in
`RawCullSAM3.app`.

The bundled `.aimodel` can be used directly. Core AI will specialize it on
first load, so ahead-of-time compilation is optional.

## Getting The Model

The exporter downloads `facebook/sam3` from Hugging Face and converts it to Core
AI. If Hugging Face requires authentication, create a read token at:

```text
https://huggingface.co/settings/tokens
```

Then log in before exporting:

```sh
huggingface-cli login
```

Alternatively, provide the token only for the export command:

```sh
HF_TOKEN=hf_your_token_here make sam3-export
```

Do not commit a Hugging Face token or write it into the repository.

Export the local bundle with:

```sh
make sam3-export
```

This runs:

```sh
uv run tools/export_sam3.py --dtype float16 --overwrite
```

The exporter writes:

```text
RawCullSAM3/Resources/Models/SAM3/metadata.json
RawCullSAM3/Resources/Models/SAM3/sam3_float16.aimodel
RawCullSAM3/Resources/Models/SAM3/sam3_float16_source.aimodel
RawCullSAM3/Resources/Models/SAM3/tokenizer/tokenizer.json
RawCullSAM3/Resources/Models/SAM3/tokenizer/tokenizer_config.json
```

After export, `metadata.json` should point at the runtime model:

```json
{
  "assets": {
    "main": "sam3_float16.aimodel"
  }
}
```

## Makefile Commands

The repository `Makefile` is intentionally small now. It keeps the normal local
workflow focused on building RawCullSAM3 and verifying that the selected SAM3
asset is installed outside the signed app bundle.

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

After the build finishes, `verify-release-model` checks the external model
install location:

```text
~/Library/Application Support/RawCull/Models/SAM3
```

Install the local development model bundle there with:

```sh
make install-sam3-model
```

This copies:

```text
RawCullSAM3/Resources/Models/SAM3
```

to:

```text
~/Library/Application Support/RawCull/Models/SAM3
```

The verification step reads `assets.main` from the installed `metadata.json`.
It requires:

```text
~/Library/Application Support/RawCull/Models/SAM3/metadata.json
~/Library/Application Support/RawCull/Models/SAM3/tokenizer/tokenizer.json
~/Library/Application Support/RawCull/Models/SAM3/<assets.main>
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

It builds the app with `-configuration Debug`, then performs the same external
SAM3 model verification.

If you only want to build and skip the model verification, use:

```sh
make build-release
make build-debug
```

If you already built in Xcode and only want to check whether the external model
is installed, use:

```sh
make verify-model
```

For local release testing, use:

```sh
make build-release
make install-sam3-model
sudo ditto "$(make print-release-app)" "/Applications/RawCullSAM3.app"
open "/Applications/RawCullSAM3.app"
```

Do not copy SAM3 model files into:

```text
/Applications/RawCullSAM3.app/Contents/Resources
```

Changing the app bundle after signing can invalidate the app signature.

To print the latest discovered app bundle path without rebuilding:

```sh
make print-release-app
make print-debug-app
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

To compile a GPU-preferred asset that matches the CoreAIImageSegmenter package's
dynamic-model loading preference:

```sh
make sam3-compile-gpu
make sam3-use-asset SAM3_ASSET=sam3_float16_source.gpu.aimodelc
```

The GPU-compiled asset is optional. The known-good development path is the
runtime `.aimodel` selected by `make sam3-export`.

After a successful compile, select the asset RawCull should load by updating the
SAM3 bundle metadata:

```sh
make sam3-use-asset
```

By default, this selects:

```text
sam3_float16.aimodel
```

To select a different compiled or uncompiled asset:

```sh
make sam3-use-asset SAM3_ASSET=<asset-name>
```

Examples:

```sh
make sam3-use-asset SAM3_ASSET=sam3_float16_source.h16c.aimodelc
make sam3-use-asset SAM3_ASSET=sam3_float16_source.gpu.aimodelc
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
