#!/usr/bin/env python3
"""Correlations between body girths left over once height, weight and BMI are known.

AnthropometricPrior predicts each girth from height, weight and BMI on its own. What
it can't explain (the residual) is still somewhat shared between girths: someone with
broad hips for their height and weight tends to have broad thighs too. These residual
correlations, from ANSUR II (men, women, and both together), let measured girths sharpen
the estimate of unmeasured ones (Gaussian conditioning in
AnthropometricPrior.conditioned). Prints the Swift table.

Usage: fit_correlations.py <ANSUR data dir>
"""
import os
import sys

import numpy as np

COLUMNS = {
    "chest": "chestcircumference", "waist": "waistcircumference", "hip": "buttockcircumference",
    "thigh": "thighcircumference", "neck": "neckcircumferencebase", "upperArm": "bicepscircumferenceflexed",
    "forearm": "forearmcircumferenceflexed", "wrist": "wristcircumference", "knee": "lowerthighcircumference",
    "calf": "calfcircumference", "ankle": "anklecircumference",
}


def residuals(path):
    with open(path, encoding="latin1") as f:
        header = [h.lower() for h in f.readline().strip().split(",")]
        rows = [l.strip().split(",") for l in f if l.strip()]
    col = lambda n: np.array([float(r[header.index(n)]) for r in rows]) / 10
    h, w = col("stature"), col("weightkg")
    x = np.column_stack([np.ones(len(h)), h, w, w / (h / 100) ** 2])
    out = []
    for name in COLUMNS.values():
        y = col(name)
        coef, *_ = np.linalg.lstsq(x, y, rcond=None)
        out.append(y - x @ coef)
    return np.column_stack(out)


d = sys.argv[1]
male = residuals(os.path.join(d, "ANSUR_II_MALE_Public.csv"))
female = residuals(os.path.join(d, "ANSUR_II_FEMALE_Public.csv"))
keys = list(COLUMNS)
print("    static let order: [BodyDimension] = [" + ", ".join("." + k for k in keys) + "]")
for label, r in (("male", male), ("female", female), ("nil", np.vstack([male, female]))):
    c = np.corrcoef(r.T)
    print(f"    // {label}")
    print("    [")
    for row in c:
        print("        [" + ", ".join(f"{v:.3f}" for v in row) + "],")
    print("    ],")
