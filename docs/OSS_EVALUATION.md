# Open-source avatar, pattern and cloth projects: suitability for WearIQ (2026-10-31)

Checked against each project's source and licence files, not its README alone. The app
must run entirely on the iPhone (iOS 17, iPhone 13 and later); Python tools may run
offline, at development time, as long as what ships is data.

| | SOMA-X | GarmentCode | ClothCraft | Open+Pattern |
|---|---|---|---|---|
| What | Parametric body model (PCA shape + rig) | Parametric sewing patterns as code | Garment editor + cloth solver | Patterns digitised from real garments |
| Code licence | Apache-2.0 | MIT | MIT | — (no code) |
| Data/weights | `SOMA_neutral.npz` Apache-2.0; HF model card: "ready for commercial use". SMPL/SMPL-X/MANO backends need separately licensed files (not used) | Bodies with "smpl" in the name are SMPL-derived (its notice says CC BY 4.0; not verified, not used); the others come from GarmentMeasurements | MakeHuman mannequin CC0 | CC BY 4.0 (attribution) |
| Language / deps | Python, torch, NVIDIA Warp, usd-core, trimesh | Python, numpy, svgpathtools, libigl; simulation in a fork of NVIDIA Warp (CUDA) or Maya + Qualoth | Rust 2024, glam, rayon, serde; GUI eframe/wgpu | DXF, PDF, CLO3D, GLB files |
| Builds for iOS? | No (Python/CUDA). Not needed: the model is linear, `mean + Σ cₖ·dirₖ` | Pattern code: no (Python). Simulator: no (CUDA) | The core could cross-compile (`aarch64-apple-ios`, no GUI feature) | n/a |
| Speed | Body in a few ms on the phone (32 × 4,505 × 3 multiply-adds) | n/a on device | Its own solver lab: 252–1,436 ms **per step** on a desktop CPU (VBD and variants); a drape needs hundreds of steps | n/a |
| Maturity | NVIDIA release v0.3, 851★ | Published research (SIGGRAPH Asia 2023), 489★ | Self-described "research prototype, not a production garment tool", 50★; T-shirt template is "a two-panel engineering fixture, not a graded sewing pattern" | Real garments, single sizes or graded sets |
| Integration cost | Low: offline export script + Swift loader | Medium–high: port the panel formulas to Swift and add sewing (placing flat panels round the body and closing seams) to the XPBD solver | High (FFI, CI Rust toolchain) for a solver too slow for a phone | Low as reference data; not parametric, so no use for size-chart-driven garments |
| Decision | **Integrated** (this commit) | **Next**: port `tee.py` / `sleeves.py` panel geometry | **Not integrated**; keep our XPBD CPU solver | **Not integrated**; candidate validation data (real T-shirt pattern vs our cut) |

## SOMA-X, as integrated

- `scripts/build_soma_body.py` reads only two data files from the SOMA-X repository:
  - `SOMA_neutral.npz` (with `allow_pickle=False`);
  - `SOMA_template_rig.usda` (as text, for the skinning weights that split the mesh into torso, arms, legs, hands, feet and head).
  No SOMA-X code runs, here or on the phone.
- The script writes `WearIQKit/Sources/AvatarEngine/Resources/SomaBody.bin` (0.98 MB):
  - the 4,505-vertex mesh, with its first 32 shape components (99.7% of the variance), 16-bit;
  - landmark vertices (crotch, navel, nipple, buttock, acromion);
  - the seams between parts;
  - a linear model of how the components move the app's eight measurements.
- Sampled bodies: 6,000. The linear model's residual SD is 0.0–0.9 cm. Held-out bodies rebuilt from their eight measurements come back within 0.06–0.48 cm, mean per measurement.
- Measurements are taken as a tape would:
  - girths are the convex hull of a level cut;
  - shoulder and arm are scaled to the ANSUR II bone-measure proportions (×1.031 and ×1.120);
  - thigh and arm are averaged over both sides, so the shape stays symmetric.
- On the phone (`SomaBody.swift`, `SomaBodyModel.swift`):
  - The app finds the most likely coefficients for the measurements: weighted least squares with a prior toward the average body, two corrections against the built body, components clamped to ±3.5 SD.
  - The SOMA skin is what's shown.
  - The garments' distance field is taken from that skin:
    - the torso as 48-direction outlines every ~1.2 cm;
    - arms and legs as capsule chains every ~6%, each the smallest circle round the skin there.
  - Garments are kept 6 mm off it. Test: under 1% of skin points stand more than 1 cm out of the field.
- If the resource can't be read, the previous procedural body is used.
- Licence: Apache-2.0 text ships in the package (`SOMA-X-LICENSE.txt`) and is shown under Profile → Acknowledgements.

### Limits

- The body is SOMA's neutral (mixed-sex) model. Sex is not an input, so the chest shape comes from the girths alone.
- The pose is SOMA's own A-pose (arms ~45°). No re-posing.
- The skin is the low-LOD mesh (4,505 vertices), which shows facets in close-ups.
- The SizeUSA scans behind the PCA are licensed to NVIDIA. The released model is stated as fit for commercial use, but the training data's own terms are not ours to check.
- The measurement definitions on the mesh were chosen by us; they are not validated against tape measurements of real people (see VALIDATION.md §6).
