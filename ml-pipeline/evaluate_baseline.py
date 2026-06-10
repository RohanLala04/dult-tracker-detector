"""Evaluate the rule-based co-travel heuristic on the held-out test split.

The baseline mirrors the detector app's CoTravelDetector logic:
flag a device when (2+ distinct locations OR 10+ minutes of continuous
observation) AND separated in more than half of its sightings. The recency
condition is satisfied by construction, since every synthetic device is
observed within its window.

The train/test split (30% test, stratified, seed 42) is shared with
train.py so the classifier is always compared on exactly the same devices.

Usage: uv run python evaluate_baseline.py [--data PATH]
"""

from __future__ import annotations

import argparse
from pathlib import Path

import pandas as pd
from sklearn.metrics import confusion_matrix, precision_recall_fscore_support
from sklearn.model_selection import train_test_split

DEFAULT_DATA = Path(__file__).parent / "data" / "synthetic.csv"

SPLIT_SEED = 42
TEST_FRACTION = 0.3

# Thresholds copied from the app (CoTravelDetector).
MIN_DISTINCT_LOCATIONS = 2
MIN_CONTINUOUS_SECONDS = 600
MIN_SEPARATED_RATIO = 0.5


def split(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """The canonical train/test split, shared with train.py."""
    return train_test_split(
        df, test_size=TEST_FRACTION, stratify=df["label"], random_state=SPLIT_SEED
    )


def baseline_predict(df: pd.DataFrame) -> pd.Series:
    traveled = (df["distinct_locations"] >= MIN_DISTINCT_LOCATIONS) | (
        df["duration_s"] >= MIN_CONTINUOUS_SECONDS
    )
    return (traveled & (df["separated_ratio"] > MIN_SEPARATED_RATIO)).astype(int)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    args = parser.parse_args()

    df = pd.read_csv(args.data)
    _, test = split(df)
    predictions = baseline_predict(test)

    precision, recall, f1, _ = precision_recall_fscore_support(
        test["label"], predictions, average="binary", zero_division=0
    )
    tn, fp, fn, tp = confusion_matrix(test["label"], predictions).ravel()

    print(f"rule-based baseline on held-out test set ({len(test)} devices)")
    print(f"  precision: {precision:.3f}")
    print(f"  recall:    {recall:.3f}")
    print(f"  f1:        {f1:.3f}")
    print(f"  confusion: TP={tp} FP={fp} FN={fn} TN={tn}")

    errors = test.assign(prediction=predictions)
    false_positives = errors[(errors["label"] == 0) & (errors["prediction"] == 1)]
    false_negatives = errors[(errors["label"] == 1) & (errors["prediction"] == 0)]
    print("\nfalse positives by archetype:")
    print(false_positives["archetype"].value_counts().to_string()
          if len(false_positives) else "  none")
    print("\nfalse negatives by archetype:")
    print(false_negatives["archetype"].value_counts().to_string()
          if len(false_negatives) else "  none")


if __name__ == "__main__":
    main()
