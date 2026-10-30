#!/usr/bin/env python3
"""Fits AnthropometricPrior's models for the detail measurements on ANSUR II.

Neck, upper arm, forearm, wrist, abdomen, knee, calf and ankle aren't seen well enough in
the silhouette to measure; they are estimated from height, weight and BMI as the other
prior models are. ANSUR II measures the upper arm and forearm flexed; a sleeve fits the
relaxed arm. The ANSUR flexed-biceps model, applied to NHANES 2017–March 2020 adults
(18–65), predicts on average 1.9 cm (men) and 0.9 cm (women) more than NHANES' relaxed
mid-upper-arm circumference, so the upper arm is shifted by that much. (Part of that gap
is the populations differing, so it's a correction, not a measurement.)

Mapping: neck = neckcircumferencebase (where a collar sits), upperArm = bicepscircumference
flexed − 1.9 (men) / 0.9 (women), forearm = forearmcircumferenceflexed, wrist = wristcircumference,
knee = lowerthighcircumference (just above the kneecap, where a trouser leg is measured),
calf = calfcircumference, ankle = anklecircumference. ANSUR has no abdomen girth (its
waist is already at the navel), so the abdomen isn't fitted.

Model per sex (and pooled): value = a + b·height + c·weight + d·BMI, residual SD in cm.
Prints Swift lines to paste into AnthropometricPrior.

Usage: fit_detail_prior.py <ANSUR data dir>
"""
import os
import sys

import numpy as np

ansur_dir = sys.argv[1]
COLUMNS = {
    "neck": ("neckcircumferencebase", 0.0),
    "upperArm": ("bicepscircumferenceflexed", 0.0),
    "forearm": ("forearmcircumferenceflexed", 0.0),
    "wrist": ("wristcircumference", 0.0),
    "knee": ("lowerthighcircumference", 0.0),
    "calf": ("calfcircumference", 0.0),
    "ankle": ("anklecircumference", 0.0),
}


RELAXED_ARM_SHIFT = {"male": -1.9, "female": -0.9}


def load(file, sex):
    with open(os.path.join(ansur_dir, file), encoding="latin1") as f:
        header = f.readline().strip().split(",")
        rows = [line.strip().split(",") for line in f if line.strip()]
    idx = {name.lower(): i for i, name in enumerate(header)}
    def col(name):
        return np.array([float(r[idx[name]]) for r in rows])
    data = {"height": col("stature") / 10, "weight": col("weightkg") / 10}
    for key, (name, shift) in COLUMNS.items():
        data[key] = col(name) / 10 + shift
    data["upperArm"] = data["upperArm"] + RELAXED_ARM_SHIFT[sex]
    return data


male = load("ANSUR_II_MALE_Public.csv", "male")
female = load("ANSUR_II_FEMALE_Public.csv", "female")
pooled = {k: np.concatenate([male[k], female[k]]) for k in male}

for label, d in (("male", male), ("female", female), ("nil", pooled)):
    bmi = d["weight"] / (d["height"] / 100) ** 2
    x = np.column_stack([np.ones(len(bmi)), d["height"], d["weight"], bmi])
    print(f"        .{label}: [" if label != "nil" else "        nil: [")
    for key in COLUMNS:
        y = d[key]
        coef, *_ = np.linalg.lstsq(x, y, rcond=None)
        sd = float(np.std(y - x @ coef, ddof=4))
        a, b, c, e = coef
        print(f"            .{key}: Model(a: {a:.4f}, b: {b:.4f}, c: {c:.4f}, d: {e:.4f}, sd: {sd:.2f}),")
    print("        ],")
