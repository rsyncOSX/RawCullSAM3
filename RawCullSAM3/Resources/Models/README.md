# SAM3 Core AI Model

Place the local SAM3 Core AI model resource for development here, or install it
for app/runtime use at:

```text
~/Library/Application Support/RawCull/Models/SAM3
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
