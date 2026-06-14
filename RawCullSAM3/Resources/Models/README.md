# Core AI Model Resources

Place local Core AI model resources for development here, or install them for
app/runtime use under:

```text
$(HOME)/Library/Containers/no.blogspot.RawCullSAM3/Data/Library/Application Support/RawCullSAM3/Models
```

## SAM3

Install SAM3 at:

```text
$(HOME)/Library/Containers/no.blogspot.RawCullSAM3/Data/Library/Application Support/RawCullSAM3/Models/SAM3
```

RawCull checks the Application Support install location first. Debug builds may
also fall back to a bundled Core AI model bundle named `SAM3` for local
development. Release/App Store builds should not include the model files in the
app bundle.

The package loader expects the `SAM3` folder to contain `metadata.json`, the
asset named by `metadata.json` `assets.main`, and the tokenizer assets required
by SAM3.

For migration/dev convenience, RawCull also checks for:

- `SAM3.aimodelc`
- `SAM3.aimodel`

The `.aimodel` bundle can be used uncompiled; Core AI specializes it on first
load. To regenerate the bundle with an additional AOT source asset, run:

```sh
uv run tools/export_sam3.py --dtype float16 --overwrite
```

Compile the source asset, not the optimized runtime asset:

```sh
make sam3-compile
```

If compilation succeeds, update this bundle's `metadata.json` `assets.main`
value to the generated `.aimodelc`. If the compiler reports that the source
bytecode is missing, leave `assets.main` pointed at `sam3_float16.aimodel`.

To point the bundle at a generated compiled asset:

```sh
make sam3-use-asset ASSET=<generated-file>.aimodelc
```

`make sam3-compile` defaults to `SAM3_COMPILE_ARCH=h16c` for the local Apple M4
development machine. Use `make sam3-compile SAM3_COMPILE_ARCH=<arch>` for a
different target, or `make sam3-compile-all` for every supported architecture.

## CLIP

Generate the CLIP Core AI bundle with:

```sh
make clip-export
```

This exports `openai/clip-vit-base-patch32` as:

```text
RawCullSAM3/Resources/Models/CLIP/metadata.json
RawCullSAM3/Resources/Models/CLIP/clip-vit-base-patch32_float16_static.aimodel
RawCullSAM3/Resources/Models/CLIP/clip-vit-base-patch32_float16_static_source.aimodel
RawCullSAM3/Resources/Models/CLIP/tokenizer/tokenizer.json
```

Install CLIP for local app/runtime use with:

```sh
make install-clip-model
```

The installed bundle path is:

```text
$(HOME)/Library/Containers/no.blogspot.RawCullSAM3/Data/Library/Application Support/RawCullSAM3/Models/CLIP
```

The default export uses static shapes: one image and two padded text prompts.
For retrieval workflows that need variable image/text batch counts, run the
exporter directly with `--dynamic`.
