# Measurement engines A and B, and how they are compared

## Engine A: current (production)

The eight-stop turn: at each level (chest, waist, hip), π × the mean silhouette width
over the eight stops (Cauchy's formula), scaled by the typed height. The front photo's
skeleton gives the lengths, and the ANSUR statistics catch failed readings. The
clothing-aware step turns outline girths into body ranges. Source:
`StationScan`, `BodyScanViewModel.measure`.

## Engine B: SOMA-X silhouette fit (experimental)

`AvatarEngine/SilhouetteBodyFit.swift`. On the same turn, each stop is kept as a width
profile (`StopProfile`): the silhouette width on 25 torso rows (0.27–0.51 of stature
below the head) and 3 thigh rows. Only numbers are kept, no picture.

The SOMA-X body (32 shape components from 9,326 SizeUSA scans) is fitted by
Levenberg–Marquardt so that its projected widths at the eight stop angles match the
profile. Fitted together with the shape:

- each stop's angle error (prior ±8°);
- clothing thickness per edge on the torso and on the legs (prior from the attire the
  user chose: fitted 0.5 ± 0.4 cm, everyday 1.5 ± 1.5 cm);
- the typed height as a hard constraint;
- the skeleton's shoulder, arm and inseam lengths as further evidence.

Rows far off the fit (an arm in the way, a segmentation slip) are down-weighted (Huber).

Measurements are taken on the fitted mesh, as the avatar's body is: convex-hull girths
at the nipple, navel and buttock levels, and the thigh below the crotch.

- **Uncertainty:** the posterior covariance is propagated through the model's linear
  measurement map, plus a ±1 cm uncertainty in the typed height.
- **Provenance:**
  - chest, waist, hip and thigh are *observed* (silhouettes cover them);
  - neck, upper arm, forearm, wrist, knee and calf are *model* estimates (read off the
    fitted body, never seen on their own).

Visual-hull limits: concave regions are not visible in any silhouette, and the body
model fills them in. Under loose clothes the clothing thickness can't be separated from
body size, so the uncertainty widens instead of the body growing.

### Synthetic check (not evidence about real people)

`SilhouetteBodyFitTests` draws bodies from the SOMA-X shape space and renders their
profiles with the projection the fit itself uses. It adds stops 6° off, 0.3 cm of
clothing per edge and 0.6 cm of row noise. On 3 such bodies (2026-11-01):

| | B (fit) MAE | A-style π × mean width MAE |
|---|---|---|
| Chest | 0.44 cm | 1.31 cm |
| Waist | 1.07 cm | 0.95 cm |
| Hip | 0.65 cm | 1.16 cm |
| Thigh | 0.65 cm | – |

The data come from the model being fitted (an "inverse crime"), so this only shows that
the optimiser works. Real accuracy can only come from tape measurements.

## Validation mode (Profile → Measurement validation)

With it on, every scan is also measured by B. A record is saved with:

- an anonymous participant code;
- device model and LiDAR support;
- clothing;
- both engines' values with uncertainty and provenance;
- scan time, each engine's computing time and memory footprint;
- the stop profiles, so future engines can be rerun on the same scans.

The user enters tape values afterwards. What the app saves is always engine A's.

- **Report:** per measurement and engine, MAE, median absolute error, % error, bias
  (+ reads large), max error, repeatability (pooled within-participant SD over people
  scanned twice or more), failure rate, computing time and memory.
- **Export:** CSV (one row per measurement) and JSON (everything).
- **Synthetic records** (`isSynthetic`) are never counted with real ones.

### Engine choice (`EngineSelection`)

The decision is made per measurement, paired over participants, on the mean of
|B − tape| − |A − tape|:

- **B is chosen** only with at least 20 participants, an advantage of at least 0.3 cm,
  and a 95% interval that stays below zero.
- **A is kept** when it is as clearly better.
- **Otherwise the decision is "undecided"** and A stays.

If B wins some measurements and A others, the result is the hybrid. Nothing switches
automatically. Production uses A until a decision is made from real data and applied
deliberately.

### Protocol for the pilot (20–30 people)

1. Turn validation mode on and scan as usual, in the clothing recorded on the record.
2. Right after, measure with a tape:
   - chest at the nipples;
   - waist at the navel;
   - hips at the widest point of the seat;
   - thigh just below the crotch;
   - neck at its base;
   - upper arm halfway to the elbow;
   - forearm, wrist and calf at their usual sites;
   - inseam, arm length and height.
3. Scan a few people twice (same code) to measure repeatability.
4. Export the CSV/JSON.

Not yet done: no real-device run of engine B. ARKit modes (moving camera, floor-plane
scale) are later steps.
