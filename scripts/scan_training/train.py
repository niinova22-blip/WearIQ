"""Trains WearIQ's girth correction model on the synthetic filmed-turn data set and
compares it with the current engine on held-out people.

Data: `ScanDataExport` (WearIQKit/Tests/AvatarEngineTests/ScanDataExport.swift) films
every ANSUR II subject's SOMA-X body turning in front of a phone and writes, per
recording, what the phone can compute (silhouette widths fitted against angle at the
level rows and rows 1-3% of stature either side, the mask's top and floor rows), the
user's height and weight, the current engine's girths, and the girths of the filmed mesh
taken as a tape would (the labels; exact for that body).

Split by subject (the `split` column, hashed from ANSUR's subject id): 70% train, 15%
validation (choosing the model and its regularisation), 15% test (reported once). No
subject is in two splits; the script checks.

Models (all small enough to run on the phone, offline, in microseconds):
  - "cauchy": pi x the mean width at the level row (what the engine does, before its
    ANSUR calibration factor);
  - "current": the engine's own output (`TurnRecording.girths`);
  - "prior": height, weight, age and sex only (what the app knows before a scan);
  - "ridge": a linear correction of log girth from the silhouette and camera features;
  - "mlp": a one-hidden-layer network on the same features (numpy, Adam).
The one with the lowest validation MAE per level is exported to
WearIQKit/Sources/BodyMeasurementEngine/LearnedGirthModel.swift (generated), and the
test-set table is written to docs/SCAN_TRAINING.md.

Usage: python scripts/scan_training/train.py train.csv [other.csv ...] [--export]
Other files are evaluated with the models trained on the first (their test-split
subjects only): the shifted-camera set and the NHANES set.

Real data: `--real validation.json` (the app's validation export, Settings → Measurement
validation → Export JSON) evaluates the trained models on real scans with tape values,
per participant, beside engines A and B as the phone ran them. Those records carry
engine C's feature vectors (`turnFeatures`), so once there are enough of them (the app
asks for 20 participants before it trusts any comparison) they can be added to the
training set as real labels: the tape value, never an estimate.
"""
import csv
import json
import math
import sys
from pathlib import Path

import numpy as np

LEVELS = ["chest", "waist", "hip"]
OFFSETS = range(7)  # -3% .. +3% of stature, 3 is the level row
ROOT = Path(__file__).resolve().parents[2]


def load(path):
    rows = list(csv.DictReader(open(path, encoding="utf-8")))
    splits = {}
    for r in rows:
        s = splits.setdefault(r["subject"], r["split"])
        assert s == r["split"], f"subject {r['subject']} in two splits"
    return rows


def num(x):
    return float(x) if x not in ("", None) else math.nan


FEATURES = 27


def features(r, level):
    """Engine C's features for one level, as the phone computes them
    (`LearnedGirthModel.features`, written by the export as f_<level>_<i>): the one
    definition shared by training and the app."""
    f = [num(r.get(f"f_{level}_{i}", "")) for i in range(FEATURES)]
    if any(math.isnan(v) for v in f):
        return None
    return f


def prior_features(r):
    h = num(r["height"]); w = num(r["weight"]); a = num(r["age"])
    sex = 1.0 if r["sex"] == "female" else 0.0
    bmi = w / (h / 100) ** 2
    return [h / 100, w / 50, bmi / 25, a / 40, sex, sex * bmi / 25, sex * h / 100]


def matrix(rows, level, fn):
    X, y, keep = [], [], []
    for i, r in enumerate(rows):
        f = fn(r, level) if fn is features else fn(r)
        t = num(r[f"mesh_{level}"])
        if f is None or not t > 0 or any(math.isnan(v) for v in f):
            continue
        X.append(f); y.append(t); keep.append(i)
    return np.array(X), np.array(y), keep


class Ridge:
    def fit(self, X, y, lam):
        self.mu = X.mean(0); self.sd = X.std(0) + 1e-9
        Z = (X - self.mu) / self.sd
        A = Z.T @ Z + lam * np.eye(Z.shape[1])
        self.b0 = y.mean()
        self.w = np.linalg.solve(A, Z.T @ (y - self.b0))
        return self

    def predict(self, X):
        return self.b0 + ((X - self.mu) / self.sd) @ self.w


class MLP:
    def fit(self, X, y, hidden=24, epochs=400, lr=3e-3, l2=1e-4, seed=0, Xv=None, yv=None):
        rng = np.random.default_rng(seed)
        self.mu = X.mean(0); self.sd = X.std(0) + 1e-9
        self.ym = y.mean(); self.ys = y.std() + 1e-9
        Z = (X - self.mu) / self.sd; t = (y - self.ym) / self.ys
        n, d = Z.shape
        p = {"W1": rng.normal(0, 1 / math.sqrt(d), (d, hidden)), "b1": np.zeros(hidden),
             "W2": rng.normal(0, 1 / math.sqrt(hidden), hidden), "b2": 0.0}
        m = {k: np.zeros_like(v) if isinstance(v, np.ndarray) else 0.0 for k, v in p.items()}
        v2 = {k: np.zeros_like(v) if isinstance(v, np.ndarray) else 0.0 for k, v in p.items()}
        best, best_p, step = math.inf, None, 0
        for epoch in range(epochs):
            order = rng.permutation(n)
            for s in range(0, n, 256):
                idx = order[s:s + 256]
                x, tt = Z[idx], t[idx]
                h = np.tanh(x @ p["W1"] + p["b1"])
                out = h @ p["W2"] + p["b2"]
                g = 2 * (out - tt) / len(idx)
                grads = {"W2": h.T @ g + l2 * p["W2"], "b2": g.sum()}
                gh = np.outer(g, p["W2"]) * (1 - h ** 2)
                grads["W1"] = x.T @ gh + l2 * p["W1"]; grads["b1"] = gh.sum(0)
                step += 1
                for k in p:
                    m[k] = 0.9 * m[k] + 0.1 * grads[k]
                    v2[k] = 0.999 * v2[k] + 0.001 * grads[k] ** 2
                    mh = m[k] / (1 - 0.9 ** step); vh = v2[k] / (1 - 0.999 ** step)
                    p[k] = p[k] - lr * mh / (np.sqrt(vh) + 1e-8)
            if Xv is not None and epoch % 10 == 9:
                self.p = p
                e = np.abs(self.predict(Xv) - yv).mean()
                if e < best:
                    best, best_p = e, {k: (v.copy() if isinstance(v, np.ndarray) else v) for k, v in p.items()}
        self.p = best_p or p
        return self

    def predict(self, X):
        Z = (X - self.mu) / self.sd
        h = np.tanh(Z @ self.p["W1"] + self.p["b1"])
        return (h @ self.p["W2"] + self.p["b2"]) * self.ys + self.ym


def stats(err):
    err = np.asarray(err)
    return {"n": int(len(err)), "mae": float(np.abs(err).mean()), "rmse": float(np.sqrt((err ** 2).mean())),
            "bias": float(err.mean()), "p95": float(np.percentile(np.abs(err), 95))}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path, others = args[0], args[1:]
    export = "--export" in sys.argv
    other_rows = {Path(o).stem: [r for r in load(o) if r["split"] == "test"] for o in others}
    rows = load(path)
    by = {s: [r for r in rows if r["split"] == s] for s in ("train", "val", "test")}
    subjects = {s: {r["subject"] for r in v} for s, v in by.items()}
    assert not (subjects["train"] & subjects["test"]) and not (subjects["val"] & subjects["test"])
    print({s: (len(v), len(subjects[s])) for s, v in by.items()})

    report, chosen = {}, {}
    for level in LEVELS:
        Xtr, ytr, _ = matrix(by["train"], level, features)
        Xva, yva, _ = matrix(by["val"], level, features)
        Xte, yte, kte = matrix(by["test"], level, features)
        # Targets as log girth: corrections are proportional.
        lt, lv = np.log(ytr), np.log(yva)
        best = None
        for lam in (0.1, 1, 10, 100, 1000):
            r = Ridge().fit(Xtr, lt, lam)
            e = np.abs(np.exp(r.predict(Xva)) - yva).mean()
            if best is None or e < best[0]:
                best = (e, lam, r)
        ridge = best[2]
        mlp = MLP().fit(Xtr, lt, Xv=Xva, yv=lv)
        val = {"ridge": best[0], "mlp": float(np.abs(np.exp(mlp.predict(Xva)) - yva).mean())}
        # Prior: height/weight/age/sex only.
        Ptr, ptr, _ = matrix(by["train"], level, prior_features)
        Pte, pte, _ = matrix(by["test"], level, prior_features)
        prior = Ridge().fit(Ptr, np.log(ptr), 1.0)

        test_rows = [by["test"][i] for i in kte]
        res = {
            "cauchy": stats(np.exp(Xte[:, 0]) - yte),
            "current": stats([num(r[f"old_{level}"]) - num(r[f"mesh_{level}"]) for r in test_rows
                              if num(r[f"old_{level}"]) > 0]),
            "prior": stats(np.exp(prior.predict(Pte)) - pte),
            "ridge": stats(np.exp(ridge.predict(Xte)) - yte),
            "mlp": stats(np.exp(mlp.predict(Xte)) - yte),
            # The mesh against ANSUR's own tape: how far the labels are from real tapes.
            "mesh_vs_tape": stats([num(r[f"mesh_{level}"]) - num(r[f"ansur_{level}"]) for r in test_rows]),
        }
        for sex in ("male", "female"):
            idx = [i for i, r in enumerate(test_rows) if r["sex"] == sex]
            res[f"ridge_{sex}"] = stats(np.exp(ridge.predict(Xte[idx])) - yte[idx])
            res[f"current_{sex}"] = stats([num(test_rows[i][f"old_{level}"]) - yte[i] for i in idx
                                           if num(test_rows[i][f"old_{level}"]) > 0])
        for name, orows in other_rows.items():
            Xo, yo, ko = matrix(orows, level, features)
            kept = [orows[i] for i in ko]
            res[f"{name}:current"] = stats([num(r[f"old_{level}"]) - num(r[f"mesh_{level}"]) for r in kept
                                            if num(r[f"old_{level}"]) > 0])
            res[f"{name}:ridge"] = stats(np.exp(ridge.predict(Xo)) - yo)
            res[f"{name}:mlp"] = stats(np.exp(mlp.predict(Xo)) - yo)
            Po, po, _ = matrix(orows, level, prior_features)
            res[f"{name}:prior"] = stats(np.exp(prior.predict(Po)) - po)
        best_model = ridge if val["ridge"] <= val["mlp"] else mlp
        val_rmse = float(np.sqrt(((np.exp(best_model.predict(Xva)) - yva) ** 2).mean()))
        report[level] = {"val": val, "lambda": best[1], "test": res, "val_rmse": val_rmse}
        chosen[level] = ("ridge", ridge) if val["ridge"] <= val["mlp"] else ("mlp", mlp)
        print(level)
        for k, v in res.items():
            print(f"   {k:26s} n={v['n']:5d} MAE {v['mae']:.2f} RMSE {v['rmse']:.2f} bias {v['bias']:+.2f} p95 {v['p95']:.2f}")
        print("   val MAE", {k: round(v, 3) for k, v in val.items()}, "lambda", best[1])

    real = next((sys.argv[i + 1] for i, a in enumerate(sys.argv) if a == "--real" and i + 1 < len(sys.argv)), None)
    if real:
        evaluate_real(real, {lv: m for lv, (_, m) in chosen.items()}, report)

    out = Path(path).with_suffix(".report.json")
    json.dump(report, open(out, "w"), indent=1)
    print("report:", out)
    if export:
        write_swift(chosen, {lv: report[lv]["val_rmse"] for lv in chosen})


def evaluate_real(path, models, report):
    """Real scans with tape values: engines A, B and the newly trained C, against the tape."""
    records = [r for r in json.load(open(path, encoding="utf-8")) if not r.get("isSynthetic")]
    for level in LEVELS:
        rows = {"A": [], "B": [], "C (app)": [], "C (new)": []}
        for r in records:
            tape = r.get("tape", {}).get(level)
            if not tape:
                continue
            for key, engine in (("A", "A"), ("B", "B"), ("C (app)", "C")):
                v = r.get("engines", {}).get(engine, {}).get(level)
                if v:
                    rows[key].append((r["participant"], v["cm"] - tape))
            f = (r.get("turnFeatures") or {}).get(level)
            if f and len(f) == FEATURES:
                rows["C (new)"].append((r["participant"], float(np.exp(models[level].predict(np.array([f])))[0]) - tape))
        report.setdefault("real", {})[level] = {}
        print(f"real {level}:")
        for key, pairs in rows.items():
            if not pairs:
                continue
            # Each participant counts once: their scans' errors averaged.
            per = {}
            for p, e in pairs:
                per.setdefault(p, []).append(e)
            errs = [float(np.mean(v)) for v in per.values()]
            st = stats(errs)
            report["real"][level][key] = st
            print(f"   {key:8s} participants={st['n']:3d} MAE {st['mae']:.2f} RMSE {st['rmse']:.2f} bias {st['bias']:+.2f}")


def write_swift(chosen, sds):
    """The chosen models as Swift constants (ridge: standardised weights; an MLP is
    exported only if it won on validation)."""
    def sd(level):
        # Validation RMSE, doubled for the gap between synthetic and real recordings
        # until real tape data measures it.
        return f"{2 * sds[level]:.2f}"

    lines = ["// Generated by scripts/scan_training/train.py. Do not edit by hand.", "",
             "extension LearnedGirthModel {", "    static let trained: [BodyLevel: Weights] = ["]
    for level, (kind, m) in chosen.items():
        if kind == "ridge":
            lines.append(f"        .{level}: Weights(kind: .linear, mean: {fmt(m.mu)}, scale: {fmt(m.sd)},")
            lines.append(f"                          intercept: {float(m.b0)!r}, weights: {fmt(m.w)}, sdCm: {sd(level)}),")
        else:
            p = m.p
            lines.append(f"        .{level}: Weights(kind: .network, mean: {fmt(m.mu)}, scale: {fmt(m.sd)},")
            lines.append(f"                          intercept: {float(float(p['b2']) * m.ys + m.ym)!r}, weights: {fmt(p['W2'] * m.ys)},")
            lines.append(f"                          hidden: {fmt(p['W1'].T.reshape(-1))}, hiddenBias: {fmt(p['b1'])}, sdCm: {sd(level)}),")
    lines += ["    ]", "}", ""]
    target = ROOT / "WearIQKit/Sources/BodyMeasurementEngine/LearnedGirthModel+Weights.swift"
    target.write_text("\n".join(lines), encoding="utf-8")
    print("wrote", target)


def fmt(a):
    return "[" + ", ".join(f"{float(x):.6g}" for x in np.ravel(a)) + "]"


if __name__ == "__main__":
    main()
