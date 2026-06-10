"""Generate labeled synthetic co-travel data for the follower classifier.

Simulates a user moving through a sequence of locations over several hours
while BLE devices advertise around them, then reduces each device to the
same six features the macOS app computes from its sightings database:

    rssi_mean, rssi_var, duration_s, distinct_locations,
    persistence_per_min, separated_ratio

Device archetypes:
    ambient_static   stationary electronics at one location (negative)
    transient        passersby, seconds to minutes (negative)
    companion        travels with the user but near-owner, e.g. a friend's
                     tag with the friend present (negative - tests the
                     separated condition)
    lost_static      a separated tag abandoned at one location (negative -
                     tests the location/duration conditions)
    follower         a separated tracker planted on the user (positive),
                     including recently planted ones seen at only the
                     final location

Ambient RSSI behavior and sighting rates are calibrated against the real
sightings database when it exists; otherwise documented defaults are used.

Usage: uv run python generate_data.py [--devices N] [--db PATH] [--out PATH]
"""

from __future__ import annotations

import argparse
import sqlite3
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

DEFAULT_DB = (
    Path.home()
    / "Library/Containers/edu.usc.rklala.DULTDetector/Data"
    / "Library/Application Support/DULTDetector/sightings.sqlite"
)
DEFAULT_OUT = Path(__file__).parent / "data" / "synthetic.csv"

FEATURES = [
    "rssi_mean",
    "rssi_var",
    "duration_s",
    "distinct_locations",
    "persistence_per_min",
    "separated_ratio",
]

# (archetype, probability, label)
ARCHETYPES = [
    ("ambient_static", 0.33, 0),
    ("transient", 0.29, 0),
    ("companion", 0.12, 0),
    ("lost_static", 0.08, 0),
    ("follower", 0.18, 1),
]

rng = np.random.default_rng(42)


@dataclass
class Calibration:
    """Ambient-device statistics drawn from real scans (or defaults)."""

    rssi_mu_mean: float = -72.0  # mean of per-device mean RSSI (dBm)
    rssi_mu_std: float = 12.0
    rssi_sigma_static: float = 3.0  # within-device RSSI std, stationary
    rate_per_min: float = 12.0  # median sighting rate of a nearby device
    source: str = "defaults (database not found or too small)"


def calibrate(db_path: Path) -> Calibration:
    if not db_path.exists():
        return Calibration()
    query = """
        SELECT COUNT(*) AS n,
               AVG(rssi) AS rssi_mean,
               AVG(rssi * rssi) - AVG(rssi) * AVG(rssi) AS rssi_var,
               MAX(timestamp) - MIN(timestamp) AS duration
        FROM sightings
        WHERE rssi != 127
        GROUP BY peripheral_uuid
        HAVING n >= 20 AND duration >= 60
    """
    with sqlite3.connect(db_path) as conn:
        per_device = pd.read_sql_query(query, conn)
    if len(per_device) < 10:
        return Calibration()
    rate = (per_device["n"] / (per_device["duration"] / 60.0)).median()
    return Calibration(
        rssi_mu_mean=float(per_device["rssi_mean"].mean()),
        rssi_mu_std=float(per_device["rssi_mean"].std()),
        rssi_sigma_static=float(np.sqrt(per_device["rssi_var"].clip(lower=0).median())),
        rate_per_min=float(rate),
        source=f"calibrated on {len(per_device)} real devices from {db_path.name}",
    )


def sample_itinerary() -> list[float]:
    """Dwell time in minutes at each location the user visits (2-4 places)."""
    n_locations = int(rng.integers(2, 5))
    dwells = rng.lognormal(mean=np.log(60), sigma=0.6, size=n_locations)
    return list(np.clip(dwells, 20, 300))


def make_device(archetype: str, label: int, dwells: list[float], cal: Calibration) -> dict:
    """Sample one device's sightings summary for the given user itinerary."""
    rssi_mu = rng.normal(cal.rssi_mu_mean, cal.rssi_mu_std)
    rssi_sigma = cal.rssi_sigma_static
    rate = cal.rate_per_min * rng.uniform(0.5, 1.5)

    if archetype == "ambient_static":
        loc = int(rng.integers(0, len(dwells)))
        visible_min = dwells[loc] * rng.uniform(0.6, 1.0)
        locations = 1
        separated_ratio = 0.0

    elif archetype == "transient":
        visible_min = float(np.clip(rng.exponential(2.0), 0.2, 8.0))
        locations = 1
        # A small share are separated tags passing by (on a passerby's bag).
        separated_ratio = rng.uniform(0.6, 1.0) if rng.random() < 0.05 else 0.0

    elif archetype == "companion":
        # Travels the whole itinerary, but its owner is present.
        visible_min = sum(dwells) * rng.uniform(0.85, 1.0)
        locations = len(dwells)
        separated_ratio = float(rng.beta(2, 12))

    elif archetype == "lost_static":
        loc = int(rng.integers(0, len(dwells)))
        visible_min = dwells[loc] * rng.uniform(0.5, 1.0)
        locations = 1
        separated_ratio = rng.uniform(0.6, 0.98)

    elif archetype == "follower":
        # RSSI varies with body/bag movement; rate drops with attenuation.
        rssi_sigma = cal.rssi_sigma_static * rng.uniform(1.5, 3.5)
        rate *= rng.uniform(0.3, 1.0)
        if rng.random() < 0.25:
            # Recently planted: only the final location, possibly under the
            # 10-minute continuity threshold.
            visible_min = min(dwells[-1], rng.uniform(6.0, 45.0))
            locations = 1
        else:
            seen = [d for d in dwells if rng.random() < 0.9] or [dwells[0]]
            visible_min = sum(seen) * rng.uniform(0.8, 1.0)
            locations = max(len(seen), 1)
        # Truncated or unparsed payloads log as not-separated, diluting the
        # ratio the same way they do in the app's database.
        payload_miss = rng.uniform(0.0, 0.45)
        separated_ratio = rng.uniform(0.75, 0.98) * (1.0 - payload_miss)

    else:
        raise ValueError(archetype)

    n = max(int(rng.poisson(rate * visible_min)), 2)
    duration_s = visible_min * 60.0 * rng.uniform(0.9, 1.0)
    rssi_draws = rng.normal(rssi_mu, rssi_sigma, size=min(n, 2000))
    return {
        "rssi_mean": float(rssi_draws.mean()),
        "rssi_var": float(rssi_draws.var()),
        "duration_s": float(duration_s),
        "distinct_locations": int(locations),
        "persistence_per_min": float(n / max(duration_s / 60.0, 1.0)),
        "separated_ratio": float(np.clip(separated_ratio, 0.0, 1.0)),
        "archetype": archetype,
        "label": label,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--devices", type=int, default=6000)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()

    cal = calibrate(args.db)
    print(f"calibration: {cal.source}")
    print(
        f"  rssi mean {cal.rssi_mu_mean:.1f} dBm (sd {cal.rssi_mu_std:.1f}), "
        f"static rssi sigma {cal.rssi_sigma_static:.2f}, "
        f"sighting rate {cal.rate_per_min:.1f}/min"
    )

    names = [a[0] for a in ARCHETYPES]
    probs = [a[1] for a in ARCHETYPES]
    labels = {a[0]: a[2] for a in ARCHETYPES}

    rows = []
    for _ in range(args.devices):
        dwells = sample_itinerary()
        archetype = str(rng.choice(names, p=probs))
        rows.append(make_device(archetype, labels[archetype], dwells, cal))

    df = pd.DataFrame(rows)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(args.out, index=False)

    print(f"\nwrote {len(df)} devices to {args.out}")
    print("\nclass distribution:")
    counts = df["label"].value_counts().sort_index()
    for value, count in counts.items():
        name = "following" if value == 1 else "not following"
        print(f"  {value} ({name}): {count} ({count / len(df):.1%})")
    print("\nby archetype:")
    print(df.groupby("archetype")["label"].agg(["count"]).to_string())


if __name__ == "__main__":
    main()
