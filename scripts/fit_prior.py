#!/usr/bin/env python3
"""Fits AnthropometricPrior's waist and hip models on ANSUR II and NHANES together.

ANSUR II (US Army 2012) is a fit, mostly young military population; NHANES 2017–March 2020
(CDC, public domain) is the US civilian population. Waist: ANSUR at the navel, NHANES at
the top of the hip bone, which sits at the same height (ANSUR: 0.601 vs 0.604 of
stature). Hips: both at the buttocks' fullest point.

Model per sex: value = a + b·height + c·weight + d·BMI. Prints the coefficients and the
error of each model on each dataset, so the choice is visible.

Usage: fit_prior.py <ANSUR data dir> <NHANES cache dir>
(NHANES P_BMX.xpt and P_DEMO.xpt are downloaded into the cache dir when missing.)
Needs numpy and pandas.
"""
import os
import sys
import urllib.request

import numpy as np
import pandas as pd

ansur_dir, cache = sys.argv[1], sys.argv[2]
os.makedirs(cache, exist_ok=True)
for name in ("P_BMX", "P_DEMO"):
    path = os.path.join(cache, f"{name}.xpt")
    if not os.path.exists(path):
        url = f"https://wwwn.cdc.gov/Nchs/Data/Nhanes/Public/2017/DataFiles/{name}.xpt"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req) as r, open(path, "wb") as f:
            f.write(r.read())

frames = []
for file, sex in (("ANSUR_II_MALE_Public.csv", "male"), ("ANSUR_II_FEMALE_Public.csv", "female")):
    a = pd.read_csv(os.path.join(ansur_dir, file), encoding="latin1")
    a.columns = [c.lower() for c in a.columns]
    frames.append(pd.DataFrame({
        "source": "ANSUR", "sex": sex, "height": a.stature / 10, "weight": a.weightkg / 10,
        "waist": a.waistcircumference / 10, "hip": a.buttockcircumference / 10,
    }))
bmx = pd.read_sas(os.path.join(cache, "P_BMX.xpt"))
demo = pd.read_sas(os.path.join(cache, "P_DEMO.xpt"))
n = bmx.merge(demo[["SEQN", "RIAGENDR", "RIDAGEYR", "RIDEXPRG"]], on="SEQN")
n = n[(n.RIDAGEYR >= 18) & (n.RIDAGEYR <= 65) & (n.RIDEXPRG != 1)]  # adults, not pregnant
frames.append(pd.DataFrame({
    "source": "NHANES", "sex": np.where(n.RIAGENDR == 1, "male", "female"),
    "height": n.BMXHT, "weight": n.BMXWT, "waist": n.BMXWAIST, "hip": n.BMXHIP,
}))
data = pd.concat(frames).dropna()
data = data[(data.height.between(140, 205)) & (data.weight.between(36, 160))]
data["bmi"] = data.weight / (data.height / 100) ** 2
print("rows:", data.groupby(["source", "sex"]).size().to_dict())


def design(d):
    return np.column_stack([np.ones(len(d)), d.height, d.weight, d.bmi])


def fit(d, y):
    coef, *_ = np.linalg.lstsq(design(d), d[y], rcond=None)
    return coef


def report(coef, d, y):
    r = d[y] - design(d) @ coef
    return f"bias {r.mean():+.2f}  sd {r.std():.2f}  mae {r.abs().mean():.2f}"


for y in ("waist", "hip"):
    for sex in ("male", "female", None):
        d = data if sex is None else data[data.sex == sex]
        ansur = d[d.source == "ANSUR"]
        nhanes = d[d.source == "NHANES"]
        only_ansur = fit(ansur, y)
        both = fit(d, y)
        print(f"\n{y} / {sex or 'pooled'}")
        print("  ANSUR-only model   on ANSUR:", report(only_ansur, ansur, y), " on NHANES:", report(only_ansur, nhanes, y))
        print("  combined model     on ANSUR:", report(both, ansur, y), " on NHANES:", report(both, nhanes, y))
        sd = (d[y] - design(d) @ both).std()
        print(f"  Model(a: {both[0]:.4f}, b: {both[1]:.4f}, c: {both[2]:.4f}, d: {both[3]:.4f}, sd: {sd:.2f})")

# A compact extract for the Swift validation tests (NHANES is public domain).
out = os.path.join(ansur_dir, "NHANES_2017_2020_adults.csv")
nh = data[data.source == "NHANES"][["sex", "height", "weight", "waist", "hip"]].round(1)
nh.to_csv(out, index=False)
print("wrote", out, len(nh))
