#!/usr/bin/env python3
"""Builds AvatarEngine's body shape model from NVIDIA SOMA-X (Apache-2.0).

SOMA-X (https://github.com/NVlabs/SOMA-X, model card: https://huggingface.co/nvidia/SOMA-X)
ships a native PCA body shape model, SOMA_neutral.npz: 128 components over an
18,056-vertex mesh, learned from 9,326 SizeUSA scans, 303 Triplegangers scans and
GarmentMeasurements, released under Apache-2.0 for commercial use. Its rig,
SOMA_template_rig.usda, holds the skinning weights. Only these two data files are read
(the npz with allow_pickle=False, the usda as text); no SOMA-X code is run, and
nothing is needed on the phone but the file written here.

What it writes (little-endian), for the low-LOD mesh (4,505 vertices) in metres:
  header   "SOMA" u32 version, u32 V, u32 T, u32 K, u32 M, u32 ring count
  mean     V*3 f32
  scale    K f32, then dirs K*V*3 i16 (component k = i16 * scale[k] metres, already
           multiplied by sqrt(eigenvalue), so coefficients are in standard deviations)
  tris     T*3 u16
  parts    V u8   0 torso, 1 head and neck, 2/3 left/right arm, 4/5 left/right leg,
                  6/7 left/right hand, 8/9 left/right foot
  points   u32 per landmark vertex (see LANDMARKS)
  rings    per ring: u32 count, then u32 vertex indices (see RINGS)
  model    m0 M f32, B M*K f32: measurements ≈ m0 + B·c (cm), residual SD M f32, and
           the calibration M f32 the raw measurements are multiplied by

The measurements, in this order, are the ones the app scans, defined as in ANSUR II:
height, chest (at the nipples), waist (at the navel), hip (at the buttocks' furthest
point), thigh (just below the crotch, both legs averaged), shoulder (bi-acromial, from the tops of the
shoulders), arm (shoulder top to elbow to wrist, both arms averaged) and inseam (crotch height). The app
measures the body it builds in the same way (AvatarEngine/SomaBody.swift), so the two
must change together.

Usage: build_soma_body.py <SOMA-X assets dir> <output .bin> [preview.png]
"""
import re
import struct
import sys

import numpy as np

assets, out_path = sys.argv[1], sys.argv[2]
preview = sys.argv[3] if len(sys.argv) > 3 else None
K = 32           # components kept: 99.7% of the shape variance
SAMPLES = 6000
rng = np.random.default_rng(7)

z = np.load(f"{assets}/SOMA_neutral.npz", allow_pickle=False)
low = z["lod_mid_to_low"]
tris = z["triangles_low"].astype(np.int64)
mean = z["mean"][low] / 100.0
sd = np.sqrt(z["eigenvalues"][:K])
dirs = z["shapedirs"][:K].reshape(K, -1, 3)[:, low] / 100.0 * sd[:, None, None]
V = len(mean)

# MARK: Parts, from the dominant joint in the rig's skinning weights.

usda = open(f"{assets}/SOMA_template_rig.usda", encoding="utf-8").read()
skin = usda[usda.index('def Mesh "c_skin_mid"'):]
skin = skin[: skin.index("def Mesh", 10)]
# The mesh binds its own joint list (it leaves out the root).
joints = [j.split("/")[-1] for j in re.findall(r'"([^"]+)"', re.search(r"skel:joints = \[(.*?)\]", skin, re.S).group(1))]
idx = np.array(re.search(r"jointIndices = \[(.*?)\]", skin, re.S).group(1).split(","), dtype=np.int64)
wts = np.array(re.search(r"jointWeights = \[(.*?)\]", skin, re.S).group(1).split(","), dtype=np.float64)
per = int(re.search(r"jointIndices = \[.*?\]\s*\(\s*elementSize = (\d+)", skin, re.S).group(1))
idx, wts = idx.reshape(-1, per), wts.reshape(-1, per)
assert len(idx) == len(z["mean"]), (len(idx), len(z["mean"]))


def part_of(name):
    for side, s in (("Left", 0), ("Right", 1)):
        if name.startswith(side + "Hand"):
            return 6 + s
        if name.startswith(side + "Arm") or name.startswith(side + "ForeArm"):
            return 2 + s
        if name.startswith(side + "Foot") or name.startswith(side + "Toe"):
            return 8 + s
        if name.startswith(side + "Leg") or name.startswith(side + "Shin"):
            return 4 + s
    if name.startswith(("Neck", "Head", "Jaw")) or name.endswith("Eye"):
        return 1
    return 0


joint_part = np.array([part_of(j) for j in joints])
score = np.zeros((len(idx), 10))
for c in range(per):
    np.add.at(score, (np.arange(len(idx)), joint_part[idx[:, c]]), wts[:, c])
parts = score.argmax(1)[low].astype(np.uint8)
# Finer labels for the rings: upper arm / forearm, thigh / shin.
segment = np.array([j for j in joints])[idx[np.arange(len(idx)), wts.argmax(1)]][low]


def kind(name):
    for key in ("ForeArm", "Arm", "Shin", "Leg", "Hand", "Foot", "Toe"):
        if key in name:
            return key
    return name


segment = np.array([kind(s) for s in segment])

edges = np.concatenate([tris[:, [0, 1]], tris[:, [1, 2]], tris[:, [2, 0]]])


def ring(a_mask, b_mask):
    """Vertices of A next to B: the seam between two parts."""
    e = edges[(a_mask[edges[:, 0]] & b_mask[edges[:, 1]])]
    return np.unique(e[:, 0])


side_x = mean[:, 0]
RINGS = {}
for s, name in ((0, "Left"), (1, "Right")):
    arm = (parts == 2 + s)
    leg = (parts == 4 + s)
    RINGS[f"shoulder{s}"] = ring(arm, parts == 0)
    RINGS[f"elbow{s}"] = ring(arm & (segment == "ForeArm"), arm & (segment == "Arm"))
    RINGS[f"wrist{s}"] = ring(arm, parts == 6 + s)
    RINGS[f"groin{s}"] = ring(leg, parts == 0)
    RINGS[f"knee{s}"] = ring(leg & (segment == "Shin"), leg & (segment == "Leg"))
    RINGS[f"ankle{s}"] = ring(leg, parts == 8 + s)
RINGS["neck"] = ring(parts == 1, parts == 0)
for k, r in RINGS.items():
    assert len(r) >= 4, (k, len(r))

# MARK: Landmarks, chosen once on the mean body; the topology is shared, so each one
# follows the anatomy as the shape changes.

H = mean[:, 1].max() - mean[:, 1].min()
torso = parts == 0
mid = torso & (np.abs(mean[:, 0]) < 0.015)
crotch = np.where(mid)[0][mean[mid, 1].argmin()]
front = mid & (mean[:, 2] > 0)
navel = np.where(front)[0][np.abs(mean[front, 1] - 0.598 * H).argmin()]
chest_zone = torso & (mean[:, 0] > 0.06) & (mean[:, 0] < 0.14) & (mean[:, 1] > 0.66 * H) & (mean[:, 1] < 0.78 * H)
nipple = np.where(chest_zone)[0][mean[chest_zone, 2].argmax()]
seat = torso & (np.abs(mean[:, 0]) < 0.12) & (mean[:, 1] > mean[crotch, 1]) & (mean[:, 1] < mean[crotch, 1] + 0.12 * H)
buttock = np.where(seat)[0][mean[seat, 2].argmin()]
top = np.argmax(mean[:, 1])
acromion = []
for s in (0, 1):
    r = RINGS[f"shoulder{s}"]
    acromion.append(r[mean[r, 1].argmax()])
LANDMARKS = {"crotch": crotch, "navel": navel, "nipple": nipple, "buttock": buttock, "top": top,
             "acromion0": acromion[0], "acromion1": acromion[1]}

# MARK: Measuring a body, as the app does.


def slice_points(v, keep, y):
    """Where the kept triangles cross the level y."""
    t = tris[keep[tris].all(1)]
    p = v[t]
    out = []
    for a, b in ((0, 1), (1, 2), (2, 0)):
        ya, yb = p[:, a, 1], p[:, b, 1]
        cross = (ya - y) * (yb - y) < 0
        f = (y - ya[cross]) / (yb[cross] - ya[cross])
        out.append(p[cross, a] + (p[cross, b] - p[cross, a]) * f[:, None])
    return np.concatenate(out)[:, [0, 2]] if out else np.zeros((0, 2))


def cross(a, b):
    return a[0] * b[1] - a[1] * b[0]


def hull_perimeter(pts):
    """A tape round the outside: the convex hull's perimeter (monotone chain)."""
    if len(pts) < 3:
        return 0.0
    pts = np.unique(np.round(pts, 6), axis=0)
    pts = pts[np.lexsort((pts[:, 1], pts[:, 0]))]

    def half(points):
        h = []
        for p in points:
            while len(h) >= 2 and cross(h[-1] - h[-2], p - h[-2]) <= 0:
                h.pop()
            h.append(p)
        return h

    hull = half(pts)[:-1] + half(pts[::-1])[:-1]
    hull = np.array(hull)
    return float(np.linalg.norm(hull - np.roll(hull, -1, 0), axis=1).sum())


girth_parts = np.isin(parts, (0, 4, 5))   # no arms, hands or head in a girth tape
SHOULDER_SKIN = 0.012  # each acromion point is about this far out over the bone
NAMES = ["height", "chest", "waist", "hip", "thigh", "shoulder", "arm", "inseam"]
# The shoulder and arm are bone measures in ANSUR II; on the skin they come out short.
# They are scaled so the mean body has the survey's proportions for its height
# (bi-acromial 0.232 and acromion–radiale–stylion 0.340 of stature, men and women
# pooled); the scale is written into the file and applied by the app too.
ANSUR_RATIO = {"shoulder": 0.232, "arm": 0.340}
CALIBRATION = np.ones(len(NAMES))


def centroid(v, name):
    return v[RINGS[name]].mean(0)


def measure(v):
    floor = v[:, 1].min()
    y = lambda i: v[i, 1]
    chest = hull_perimeter(slice_points(v, girth_parts, y(nipple)))
    waist = hull_perimeter(slice_points(v, girth_parts, y(navel)))
    hip = hull_perimeter(slice_points(v, girth_parts, y(buttock)))
    thigh_y = y(crotch) - 0.018 * (v[top, 1] - floor)
    # Both sides, averaged: a measurement of one side would pull the shape lopsided.
    thigh = (hull_perimeter(slice_points(v, parts == 4, thigh_y)) + hull_perimeter(slice_points(v, parts == 5, thigh_y))) / 2
    a0, a1 = v[acromion[0]], v[acromion[1]]
    shoulder = abs(a0[0] - a1[0]) - 2 * SHOULDER_SKIN
    arm = 0
    for s, a in ((0, a0), (1, a1)):
        elbow, wrist = centroid(v, f"elbow{s}"), centroid(v, f"wrist{s}")
        arm += (np.linalg.norm(a - elbow) + np.linalg.norm(elbow - wrist)) / 2
    return np.array([v[top, 1] - floor, chest, waist, hip, thigh, shoulder, arm, y(crotch) - floor]) * 100 * CALIBRATION


raw = measure(mean)
for name, ratio in ANSUR_RATIO.items():
    i = NAMES.index(name)
    CALIBRATION[i] = ratio * raw[0] / raw[i]
print("calibration:", dict(zip(NAMES, np.round(CALIBRATION, 3))))
m_mean = measure(mean)
print("mean body:", dict(zip(NAMES, np.round(m_mean, 1))))
print("landmarks:", {k: (int(i), np.round(mean[i] * 100, 1).tolist()) for k, i in LANDMARKS.items()})
print("parts:", np.bincount(parts, minlength=10).tolist(), "rings:", {k: len(r) for k, r in RINGS.items()})

# MARK: The model: measurements as a linear function of the shape coefficients.

C = rng.standard_normal((SAMPLES, K))
Mx = np.array([measure(mean + np.tensordot(c, dirs, axes=1)) for c in C])
X = np.hstack([np.ones((SAMPLES, 1)), C])
coef, *_ = np.linalg.lstsq(X, Mx, rcond=None)
pred = X @ coef
resid = Mx - pred
m0, B = coef[0], coef[1:].T
rsd = resid.std(0)
print("linear fit, residual SD (cm):", dict(zip(NAMES, np.round(rsd, 2))))
print("measurement SD in the samples (cm):", dict(zip(NAMES, np.round(Mx.std(0), 1))))

# How well the app's solve recovers held-out bodies from their eight measurements.
test = rng.standard_normal((300, K))
Mt = np.array([measure(mean + np.tensordot(c, dirs, axes=1)) for c in test])
W = np.diag(1 / np.maximum(rsd, 0.3) ** 2)
A = B.T @ W @ B + np.eye(K)
err = []
for c, m in zip(test, Mt):
    ch = np.linalg.solve(A, B.T @ W @ (m - m0))
    err.append(measure(mean + np.tensordot(ch, dirs, axes=1)) - m)
err = np.abs(np.array(err))
print("held-out bodies rebuilt from their measurements, mean |error| (cm):", dict(zip(NAMES, np.round(err.mean(0), 2))))

# MARK: Writing.

scale = np.abs(dirs).reshape(K, -1).max(1) / 32767
q = np.round(dirs.reshape(K, -1) / scale[:, None]).astype("<i2")
with open(out_path, "wb") as f:
    f.write(b"SOMA")
    f.write(struct.pack("<6I", 1, V, len(tris), K, len(NAMES), len(RINGS)))
    f.write(mean.astype("<f4").tobytes())
    f.write(scale.astype("<f4").tobytes())
    f.write(q.tobytes())
    f.write(tris.astype("<u2").tobytes())
    f.write(parts.tobytes())
    f.write(np.array([LANDMARKS[k] for k in ("crotch", "navel", "nipple", "buttock", "top", "acromion0", "acromion1")], dtype="<u4").tobytes())
    for name in ("shoulder0", "shoulder1", "elbow0", "elbow1", "wrist0", "wrist1", "groin0", "groin1",
                 "knee0", "knee1", "ankle0", "ankle1", "neck"):
        r = RINGS[name]
        f.write(struct.pack("<I", len(r)))
        f.write(r.astype("<u4").tobytes())
    f.write(m0.astype("<f4").tobytes())
    f.write(B.astype("<f4").tobytes())
    f.write(rsd.astype("<f4").tobytes())
    f.write(CALIBRATION.astype("<f4").tobytes())
print("wrote", out_path)
