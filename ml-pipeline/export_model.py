"""Export the trained follower classifier to Core AI .aimodel format.

Pipeline: load the trained CoTravelMLP -> torch.export with the
recommended decomposition table -> coreai_torch.TorchConverter ->
coreai.authoring.AIProgram -> optimize -> save_asset as .aimodel
(minimum OS v27, the default).

Also writes test_vectors.json with PyTorch reference outputs for a few
feature vectors, so the Swift integration can verify the .aimodel
produces matching probabilities on macOS 27.

Usage: uv run python export_model.py [--model PATH] [--out PATH]
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import coreai_torch
import numpy as np
import torch

from generate_data import FEATURES
from train import DEFAULT_MODEL_PATH, CoTravelMLP

DEFAULT_OUT = Path(__file__).parent / "model" / "cotravel.aimodel"

# Reference inputs spanning the interesting cases: a classic follower, a
# stationary separated tag, a near-owner companion, and an ambient device.
TEST_VECTORS = [
    # rssi_mean, rssi_var, duration_s, locations, persistence, separated
    [-70.0, 80.0, 7200.0, 3.0, 9.0, 0.85],
    [-72.0, 12.0, 5400.0, 1.0, 16.0, 0.90],
    [-68.0, 95.0, 9000.0, 3.0, 15.0, 0.10],
    [-85.0, 13.0, 3600.0, 1.0, 17.0, 0.00],
]


def load_model(path: Path) -> CoTravelMLP:
    checkpoint = torch.load(path, weights_only=True)
    state = checkpoint["state_dict"]
    model = CoTravelMLP(
        state["feature_mean"].numpy(), state["feature_std"].numpy()
    )
    model.load_state_dict(state)
    model.eval()
    return model


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL_PATH)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    model = load_model(args.model)
    example = (torch.zeros(1, len(FEATURES), dtype=torch.float32),)

    converter = coreai_torch.TorchConverter()
    converter.add_pytorch_module(
        model,
        export_fn=lambda m: torch.export.export(m, args=example).run_decompositions(
            coreai_torch.get_decomp_table()
        ),
        input_names=["features"],
        output_names=["probability"],
    )
    program = converter.to_coreai()
    program.optimize()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    # save_asset refuses to overwrite an existing bundle.
    if args.out.exists():
        shutil.rmtree(args.out)
    program.save_asset(args.out)
    size = sum(f.stat().st_size for f in args.out.rglob("*")) if args.out.is_dir() \
        else args.out.stat().st_size
    print(f"exported {args.out} ({size / 1024:.1f} KiB)")

    with torch.no_grad():
        reference = model(torch.tensor(TEST_VECTORS, dtype=torch.float32)).numpy()
    vectors_path = args.out.parent / "test_vectors.json"
    vectors_path.write_text(json.dumps(
        {
            "features": FEATURES,
            "inputs": TEST_VECTORS,
            "expected_probabilities": [round(float(p), 6) for p in reference],
        },
        indent=2,
    ))
    print(f"reference outputs: {np.round(reference, 4).tolist()}")
    print(f"wrote {vectors_path}")


if __name__ == "__main__":
    main()
