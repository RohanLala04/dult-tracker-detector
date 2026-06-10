"""Train the follower classifier MLP and compare it against the baseline.

Architecture: 6 input features -> 64 -> 32 -> 1 sigmoid. Feature
standardization is folded into the model as buffers so the exported
.aimodel needs no external scaler. Trained with Adam and binary
cross-entropy for up to 100 epochs, early-stopping on validation loss
with patience 10 (best weights restored).

Evaluation uses the identical held-out test split as evaluate_baseline.py
and prints a side-by-side baseline-vs-model comparison.

Usage: uv run python train.py [--data PATH] [--epochs 100] [--out model/cotravel_mlp.pt]
"""

from __future__ import annotations

import argparse
import copy
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from sklearn.metrics import confusion_matrix, precision_recall_fscore_support
from sklearn.model_selection import train_test_split
from torch import nn

from evaluate_baseline import DEFAULT_DATA, SPLIT_SEED, baseline_predict, split
from generate_data import FEATURES

VALIDATION_FRACTION = 0.15
BATCH_SIZE = 256
LEARNING_RATE = 1e-3
PATIENCE = 10
DEFAULT_MODEL_PATH = Path(__file__).parent / "model" / "cotravel_mlp.pt"


class CoTravelMLP(nn.Module):
    """6 -> 64 -> 32 -> 1 sigmoid, with input standardization built in."""

    def __init__(self, feature_mean: np.ndarray, feature_std: np.ndarray):
        super().__init__()
        self.register_buffer("feature_mean", torch.tensor(feature_mean, dtype=torch.float32))
        self.register_buffer("feature_std", torch.tensor(feature_std, dtype=torch.float32))
        self.net = nn.Sequential(
            nn.Linear(len(FEATURES), 64),
            nn.ReLU(),
            nn.Linear(64, 32),
            nn.ReLU(),
            nn.Linear(32, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = (x - self.feature_mean) / self.feature_std
        return torch.sigmoid(self.net(x)).squeeze(-1)


def tensors(df: pd.DataFrame) -> tuple[torch.Tensor, torch.Tensor]:
    features = torch.tensor(df[FEATURES].to_numpy(dtype=np.float32))
    labels = torch.tensor(df["label"].to_numpy(dtype=np.float32))
    return features, labels


def train_model(train_df: pd.DataFrame, epochs: int) -> CoTravelMLP:
    fit_df, val_df = train_test_split(
        train_df,
        test_size=VALIDATION_FRACTION,
        stratify=train_df["label"],
        random_state=SPLIT_SEED,
    )
    x_fit, y_fit = tensors(fit_df)
    x_val, y_val = tensors(val_df)

    # Standardization parameters come from the fitting portion only.
    mean = x_fit.mean(dim=0).numpy()
    std = np.maximum(x_fit.std(dim=0).numpy(), 1e-6)

    torch.manual_seed(SPLIT_SEED)
    model = CoTravelMLP(mean, std)
    optimizer = torch.optim.Adam(model.parameters(), lr=LEARNING_RATE)
    loss_fn = nn.BCELoss()

    best_val_loss = float("inf")
    best_state = copy.deepcopy(model.state_dict())
    epochs_without_improvement = 0

    for epoch in range(1, epochs + 1):
        model.train()
        permutation = torch.randperm(len(x_fit))
        for start in range(0, len(x_fit), BATCH_SIZE):
            batch = permutation[start : start + BATCH_SIZE]
            optimizer.zero_grad()
            loss = loss_fn(model(x_fit[batch]), y_fit[batch])
            loss.backward()
            optimizer.step()

        model.eval()
        with torch.no_grad():
            val_loss = loss_fn(model(x_val), y_val).item()

        if val_loss < best_val_loss - 1e-5:
            best_val_loss = val_loss
            best_state = copy.deepcopy(model.state_dict())
            epochs_without_improvement = 0
        else:
            epochs_without_improvement += 1
            if epochs_without_improvement >= PATIENCE:
                print(f"early stop at epoch {epoch} (best val loss {best_val_loss:.4f})")
                break
    else:
        print(f"ran all {epochs} epochs (best val loss {best_val_loss:.4f})")

    model.load_state_dict(best_state)
    model.eval()
    return model


def metrics(labels: pd.Series, predictions: np.ndarray) -> dict:
    precision, recall, f1, _ = precision_recall_fscore_support(
        labels, predictions, average="binary", zero_division=0
    )
    tn, fp, fn, tp = confusion_matrix(labels, predictions).ravel()
    return {"precision": precision, "recall": recall, "f1": f1,
            "tp": tp, "fp": fp, "fn": fn, "tn": tn}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--out", type=Path, default=DEFAULT_MODEL_PATH)
    args = parser.parse_args()

    df = pd.read_csv(args.data)
    train_df, test_df = split(df)
    print(f"train {len(train_df)} devices / test {len(test_df)} devices")

    model = train_model(train_df, args.epochs)

    x_test, _ = tensors(test_df)
    with torch.no_grad():
        model_predictions = (model(x_test).numpy() >= 0.5).astype(int)
    model_metrics = metrics(test_df["label"], model_predictions)
    baseline_metrics = metrics(test_df["label"], baseline_predict(test_df))

    print(f"\nheld-out test set ({len(test_df)} devices), threshold 0.5")
    print(f"{'metric':<11}{'baseline':>10}{'model':>10}")
    for key in ("precision", "recall", "f1"):
        print(f"{key:<11}{baseline_metrics[key]:>10.3f}{model_metrics[key]:>10.3f}")
    print("\nconfusion matrices (TP / FP / FN / TN):")
    for name, m in (("baseline", baseline_metrics), ("model", model_metrics)):
        print(f"  {name:<9} TP={m['tp']:<5} FP={m['fp']:<5} FN={m['fn']:<5} TN={m['tn']}")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {
            "state_dict": model.state_dict(),
            "features": FEATURES,
            "architecture": "6-64-32-1 sigmoid with standardization buffers",
        },
        args.out,
    )
    print(f"\nsaved model to {args.out}")


if __name__ == "__main__":
    main()
