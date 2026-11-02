"""Arm and leg girths from what a scan gives: can a learned model beat the app's
current method on real tape labels?

The app estimates the girths the turn doesn't see (upper arm, forearm, wrist, neck,
thigh, knee, calf, ankle) from height, weight, age and sex (`AnthropometricPrior`)
conditioned on the chest, waist and hip it measured (`GirthCorrelations`): jointly
normal residuals, which is a linear regression on those inputs. Here, on ANSUR II
(6,068 tape-measured adults, split by subject exactly as the turn data:
`ScanDataExport.split`), the same inputs with a scan's noise (chest, waist and hip
±2 cm), against:
  - "linear": the app's form, refitted here (the reference);
  - "mlp": a small network on the same inputs.
Labels are ANSUR's own tape values, never estimates.

Usage: python scripts/scan_training/detail_girths.py
"""
import csv
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from train import MLP, Ridge, stats  # noqa: E402

DATA = Path(__file__).resolve().parents[2] / "WearIQKit/Tests/BodyMeasurementEngineTests/Data"
TARGETS = {
    "upper arm (flexed biceps)": "bicepscircumferenceflexed", "forearm (flexed)": "forearmcircumferenceflexed",
    "wrist": "wristcircumference", "neck (base)": "neckcircumferencebase", "thigh": "thighcircumference",
    "lower thigh": "lowerthighcircumference", "calf": "calfcircumference", "ankle": "anklecircumference",
}


def split(subject):
    """`ScanDataExport.split`: SplitMix-style hash of the subject id, 70/15/15."""
    h = (subject * 0x9E3779B97F4A7C15) & 0xFFFFFFFFFFFFFFFF
    h ^= h >> 29
    b = h % 100
    return "train" if b < 70 else "val" if b < 85 else "test"


def rows():
    out = []
    for file, sex in (("ANSUR_II_MALE_Public.csv", 0.0), ("ANSUR_II_FEMALE_Public.csv", 1.0)):
        for r in csv.DictReader(open(DATA / file, encoding="latin-1")):
            r = {k.lower(): v for k, v in r.items()}
            r["_sex"] = sex
            out.append(r)
    return out


def inputs(r, rng):
    h = float(r["stature"]) / 10; w = float(r["weightkg"]) / 10; age = float(r["age"])
    # What a scan measured, with a scan's error.
    c, wa, hi = (float(r[k]) / 10 + 2 * rng.normal() for k in ("chestcircumference", "waistcircumference", "buttockcircumference"))
    return [h / 100, math.log(w), w / (h / 100) ** 2 / 25, age / 40, r["_sex"], c / 100, wa / 100, hi / 100,
            r["_sex"] * c / 100, r["_sex"] * hi / 100]


def main():
    rng = np.random.default_rng(7)
    data = rows()
    parts = {s: [r for r in data if split(int(float(r["subjectid"]))) == s] for s in ("train", "val", "test")}
    X = {s: np.array([inputs(r, rng) for r in v]) for s, v in parts.items()}
    print({s: len(v) for s, v in parts.items()})
    print(f"{'measurement':28s} {'linear (app form)':>22s} {'mlp':>22s}")
    for name, col in TARGETS.items():
        y = {s: np.array([float(r[col]) / 10 for r in v]) for s, v in parts.items()}
        lin = Ridge().fit(X["train"], y["train"], 1.0)
        mlp = MLP().fit(X["train"], y["train"], hidden=16, epochs=300, Xv=X["val"], yv=y["val"])
        a = stats(lin.predict(X["test"]) - y["test"]); b = stats(mlp.predict(X["test"]) - y["test"])
        print(f"{name:28s} MAE {a['mae']:.2f} RMSE {a['rmse']:.2f}   MAE {b['mae']:.2f} RMSE {b['rmse']:.2f}")


if __name__ == "__main__":
    main()
