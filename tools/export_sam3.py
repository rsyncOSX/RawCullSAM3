#!/usr/bin/env python3
# Copyright 2026 Apple Inc.
#
# Adapted from apple/coreai-models models/sam3/export.py for RawCullSAM3.
#
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "coreai-core==1.0.0b1",
#     "coreai-torch==0.4.0",
#     "tokenizers<0.23.0rc",
#     "torchvision",
#     "transformers>=5.5.4,<5.10.1",
# ]
#
# [tool.uv]
# index-url       = "https://pypi.org/simple"
# prerelease      = "allow"
# index-strategy  = "unsafe-best-match"
# ///
from __future__ import annotations

import argparse
import json
import shutil
import time
from pathlib import Path

import torch
import transformers
from coreai.runtime import AIModelAssetMetadata
from coreai_torch import TorchConverter, get_decomp_table


def reference_inputs(model_name: str, dtype: torch.dtype) -> dict[str, torch.Tensor]:
    processor = transformers.Sam3Processor.from_pretrained(model_name)
    text_inputs = processor.tokenizer(["dummy"], return_tensors="pt")
    return {
        "pixel_values": torch.randn(1, 3, 1008, 1008).to(dtype),
        "input_ids": text_inputs["input_ids"].to(torch.int32),
    }


class Sam3Module(torch.nn.Module):
    def __init__(self, model_id: str = "facebook/sam3"):
        super().__init__()
        self._model = transformers.Sam3Model.from_pretrained(model_id)

    def forward(self, pixel_values, input_ids):
        outputs = self._model(pixel_values=pixel_values, input_ids=input_ids)
        return (
            outputs.pred_masks,
            outputs.pred_boxes,
            outputs.pred_logits,
            outputs.presence_logits,
            outputs.semantic_seg,
        )


def default_output_dir() -> Path:
    return Path(__file__).resolve().parents[1] / "RawCullSAM3" / "Resources" / "Models"


def variant_name(model_name: str, dtype: torch.dtype) -> str:
    safe_name = Path(model_name).name
    dtype_name = str(dtype).split(".")[-1]
    return f"{safe_name}_{dtype_name}"


def build_aimodel_metadata() -> AIModelAssetMetadata:
    metadata = AIModelAssetMetadata()
    metadata.author = "N. Carion et al."
    metadata.license = "SAM License"
    metadata.model_description = (
        "SAM 3 is a unified foundation model for promptable segmentation in images "
        "and videos. It can detect, segment, and track objects using text or visual "
        "prompts such as points, boxes, and masks. This variant is explicitly for "
        "image segmentation. Source: https://github.com/facebookresearch/sam3"
    )
    metadata.creation_date = int(time.time())
    return metadata


def save_asset(coreai_program, model_path: Path) -> None:
    if model_path.exists():
        shutil.rmtree(model_path)
    coreai_program.save_asset(model_path, build_aimodel_metadata())


def write_tokenizer(dest: Path, model_id: str) -> None:
    print(f"[INFO] Saving tokenizer from {model_id} to {dest}...")
    tokenizer = transformers.AutoTokenizer.from_pretrained(model_id)
    tokenizer.save_pretrained(str(dest))


def write_bundle_metadata(bundle_dir: Path, variant: str, main_asset: str) -> None:
    metadata = {
        "metadata_version": "0.2",
        "kind": "segmenter",
        "name": variant,
        "assets": {"main": main_asset},
    }
    metadata_path = bundle_dir / "metadata.json"
    with metadata_path.open("w") as f:
        json.dump(metadata, f, indent=2)
        f.write("\n")
    print(f"[INFO] Wrote metadata to {metadata_path}.")


def create_sam3(
    output_dir: Path,
    bundle_name: str,
    model_name: str,
    dtype: torch.dtype,
    overwrite: bool,
) -> None:
    print("[INFO] Sourcing model...")
    model = Sam3Module(model_id=model_name)
    model.eval()
    model.to(dtype)

    print("[INFO] Model sourced. Running torch export with decompositions...")
    example_inputs = reference_inputs(model_name, dtype)
    with torch.autocast(device_type="cpu", dtype=dtype):
        exported = torch.export.export(
            model,
            args=(),
            kwargs=example_inputs,
        )
    exported = exported.run_decompositions(get_decomp_table())

    print("[INFO] Model exported. Converting to Core AI...")
    converter = TorchConverter().add_exported_program(
        exported_program=exported,
        input_names=["pixel_values", "input_ids"],
        output_names=[
            "pred_masks",
            "pred_boxes",
            "pred_logits",
            "presence_logits",
            "semantic_seg",
        ],
    )
    coreai_program = converter.to_coreai()
    print("[INFO] Model converted.")

    variant = variant_name(model_name, dtype)
    bundle_dir = output_dir / bundle_name
    if bundle_dir.exists():
        if not overwrite:
            raise FileExistsError(f"{bundle_dir} already exists. Pass --overwrite.")
        shutil.rmtree(bundle_dir)
    bundle_dir.mkdir(parents=True, exist_ok=True)

    source_model_path = bundle_dir / f"{variant}_source.aimodel"
    print(f"[INFO] Saving AOT source model to {source_model_path}...")
    save_asset(coreai_program, source_model_path)

    print("[INFO] Optimizing runtime model...")
    coreai_program.optimize()
    model_path = bundle_dir / f"{variant}.aimodel"
    print(f"[INFO] Saving optimized runtime model to {model_path}...")
    save_asset(coreai_program, model_path)

    write_tokenizer(bundle_dir / "tokenizer", model_name)
    write_bundle_metadata(bundle_dir, variant, f"{variant}.aimodel")
    print(f"[INFO] SAM3 bundle ready at {bundle_dir}.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Export RawCull's SAM3 Core AI bundle with an AOT source asset.",
    )
    parser.add_argument(
        "--model",
        choices=["facebook/sam3"],
        default="facebook/sam3",
        help="Model variant to convert.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=default_output_dir(),
        help="Directory that will contain the SAM3 bundle.",
    )
    parser.add_argument(
        "--bundle-name",
        default="SAM3",
        help="Bundle directory name written under --output-dir.",
    )
    parser.add_argument(
        "--dtype",
        choices=["float16", "float32"],
        default="float16",
        help="Torch dtype to use for the model.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite an existing bundle directory.",
    )
    args = parser.parse_args()

    dtype = {
        "float16": torch.float16,
        "float32": torch.float32,
    }[args.dtype]

    create_sam3(
        output_dir=args.output_dir,
        bundle_name=args.bundle_name,
        model_name=args.model,
        dtype=dtype,
        overwrite=args.overwrite,
    )


if __name__ == "__main__":
    main()
