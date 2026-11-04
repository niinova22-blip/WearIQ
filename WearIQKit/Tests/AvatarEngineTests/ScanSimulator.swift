import Foundation
@testable import AvatarEngine
@testable import BodyMeasurementEngine
import WearIQCore

/// The filmed turn as the iPhone sees it, from real body geometry instead of idealised
/// cross-sections: an ANSUR II subject's body built with the SOMA-X shape model (its
/// eight measurements matched within half a centimetre; the rest of its shape the most
/// likely for them, learned from 9,326 SizeUSA scans), turning in front of a phone
/// camera, its silhouette rows found the way the app finds them.
///
/// What it reproduces that the ellipse tables of FilmedTurnValidationTests don't:
/// - perspective: a phone 2–3 m away, 0.6–1.3 m up, tilted to frame the body; a row of
///   the picture is not a level slice of the body, and nearer parts look bigger;
/// - real cross-sections and bodies (a bust, a belly, a flat back), whose widest row in
///   the picture isn't always the tape's level;
/// - the level rows placed as the app places them (ANSUR's population ratios stretched
///   between the shoulder and hip joints, read with Vision's noise), not at the
///   person's own nipple, navel and seat;
/// - the scale from the mask's height, which hair adds to (0.5–3 cm);
/// - the mask's pixels: a 640–1280 px tall mask, edges off by a pixel or so, a slight
///   dilation that persists through the recording, one frame in twenty widened.
///
/// The arms are left out and their shoulder seams closed (in the turn they are held out
/// at shoulder height, above the levels measured). The labels are the girths of the same mesh taken
/// as a tape would (`SomaModel.measure`), so they are exact for the body that was filmed.
struct ScanSimulator {
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
        mutating func gaussian() -> Double {
            let u1 = max(uniform(), 1e-12), u2 = uniform()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    /// Row offsets around each level, as fractions of stature: the level row and rows a
    /// little above and below it, for engines that look around the level.
    static let offsets = LearnedGirthModel.offsets
    static let levels = LearnedGirthModel.levels

    struct Recording {
        var turn: TurnRecording
        /// Per level and offset, the width (cm) in every frame (nil where the row missed).
        var widths: [BodyLevel: [[Double?]]]
        var hairCm: Double
        var distance: Double
        var cameraHeight: Double
        /// What the phone can see of where it stands: the mask's top and floor rows and the
        /// person's height, as fractions of the mask's height (medians over the turn).
        var topFraction = 0.0, floorFraction = 0.0
    }

    let model: SomaModel
    let vertices: [Vec3]
    let statureM: Float
    /// Triangles drawn: everything but the arms and hands.
    let drawn: [(Int, Int, Int)]

    init(model: SomaModel, vertices v: [Vec3]) {
        self.model = model
        let floor = v.map(\.y).min() ?? 0
        var verts = v.map { Vec3($0.x, $0.y - floor, $0.z) }
        // The arms are taken out (in the turn they are held out at shoulder height) and
        // the holes they leave at the shoulder seams closed with a fan from each seam's
        // centre: the torso's side under the arm, where a tape passes. Raising the shape
        // model's arms instead isn't possible without its skeleton (not in the bundled
        // model), and turning them rigidly about the shoulder brought the armpit down to
        // the chest.
        let hidden: Set<SomaModel.Part> = [.leftArm, .rightArm, .leftHand, .rightHand]
        var tris: [(Int, Int, Int)] = []
        for t in stride(from: 0, to: model.triangles.count - 2, by: 3) {
            let a = Int(model.triangles[t]), b = Int(model.triangles[t + 1]), c = Int(model.triangles[t + 2])
            if hidden.contains(model.parts[a]) || hidden.contains(model.parts[b]) || hidden.contains(model.parts[c]) { continue }
            tris.append((a, b, c))
        }
        for side in 0..<2 {
            let ring = model.rings.shoulder[side]
            let c = model.centroid(ring, verts)
            let centre = verts.count
            verts.append(c)
            let ordered = ring.sorted { atan2(verts[$0].y - c.y, verts[$0].z - c.z) < atan2(verts[$1].y - c.y, verts[$1].z - c.z) }
            for (i, j) in zip(ordered, ordered.dropFirst() + [ordered[0]]) { tris.append((centre, i, j)) }
        }
        vertices = verts
        statureM = verts[model.points.top].y
        drawn = tris
    }

    /// Where the app would put the levels, as fractions of stature above the floor:
    /// JointHeights' population ratios stretched between this body's shoulder and hip
    /// joints, each read with Vision's error (about 0.6% of stature).
    func levelRatios(rng: inout RNG) -> [BodyLevel: Double] {
        let h = statureM
        let acromion = (vertices[model.points.acromion[0]].y + vertices[model.points.acromion[1]].y) / 2
        // The shoulder joint's centre is about 2% of stature below the acromion; the hip
        // joint about 5% above the crotch (ANSUR II: 0.820 → 0.80, 0.47 → 0.52).
        let shoulder = Double((acromion - 0.02 * h) / h) + 0.006 * rng.gaussian()
        let hip = Double((vertices[model.points.crotch].y + 0.05 * h) / h) + 0.006 * rng.gaussian()
        return JointHeights.levelRatios.mapValues { level in hip + (level - 0.52) / (0.80 - 0.52) * (shoulder - hip) }
    }

    /// One filmed turn.
    /// Diagnostics: the effects named in `off` are left out ("levels": the body's own
    /// nipple, navel and seat heights; "hair"; "camera": a far, narrow camera, no
    /// perspective; "mask": no dilation, pixel noise or widened frames; "sway").
    /// The conditions filmed in.
    enum Domain: String {
        /// The usual: 2.0–3.2 m away, 0.6–1.3 m up, a 70–78° lens, a 640–1280 px mask.
        case normal
        /// Beyond those: closer or farther (1.6–2.0 or 3.2–3.8 m), lower or higher
        /// (0.35–0.6 or 1.3–1.55 m), a narrower or wider lens (64–70° or 78–84°), more
        /// hair (2–6 cm), a coarser mask (480–640 px) with twice the edge noise and a
        /// dilation up to 3 px, turning in 6–8 or 12–16 s.
        case shifted
        /// Either of the two, at random: what the model is trained on (domain
        /// randomisation: real rooms and phones vary more than any one setting).
        case wide
        /// Effects never seen in training, for the final test: the phone rolled 2–5° off
        /// level, the user leaning 1–4° forward or back, the mask dilated more on one side
        /// than the other, hair 0–4 cm; distances and heights from the wide ranges.
        case unseen
    }

    func record(heightCm: Double, rng: inout RNG, off: Set<String> = [], domain: Domain = .normal,
                stops: Bool = false) -> Recording {
        let shifted: Bool = switch domain {
        case .normal: false
        case .shifted: true
        case .wide, .unseen: rng.uniform() < 0.5
        }
        let unseen = domain == .unseen
        let roll = unseen ? Float((rng.uniform() < 0.5 ? -1 : 1) * rng.range(2, 5) * .pi / 180) : 0
        let lean = unseen ? Float((rng.uniform() < 0.5 ? -1 : 1) * rng.range(1, 4) * .pi / 180) : 0
        let lopsided = unseen ? rng.range(0.5, 2.5) * (rng.uniform() < 0.5 ? -1 : 1) : 0
        var ratios = levelRatios(rng: &rng)
        if off.contains("levels") {
            let h = statureM
            ratios = [.chest: Double(vertices[model.points.nipple].y / h), .waist: Double(vertices[model.points.navel].y / h),
                      .hip: Double(vertices[model.points.buttock].y / h)]
        }
        func either(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
            rng.uniform() < 0.5 ? rng.range(a.0, a.1) : rng.range(b.0, b.1)
        }
        let hair = off.contains("hair") ? 0 : Float(unseen ? rng.range(0, 0.024) : shifted ? rng.range(0.012, 0.035) : rng.range(0.005, 0.03))
        let distance = off.contains("camera") ? 60 : Float(shifted ? either((1.6, 2.0), (3.2, 3.8)) : rng.range(2.0, 3.2))
        let camHeight = Float(shifted ? either((0.35, 0.6), (1.3, 1.55)) : rng.range(0.6, 1.3))
        let vfov = (off.contains("camera") ? 2.4 : Float(shifted ? either((64, 70), (78, 84)) : rng.range(70, 78))) * .pi / 180
        let maskHeight = Float(shifted ? rng.range(480, 640) : rng.range(640, 1280)), maskWidth = maskHeight * 9 / 16
        let edgeNoise = shifted ? 2.0 : 1.0
        let focal = maskHeight / 2 / tan(vfov / 2)
        // Aimed at the middle of the body.
        let pitch = atan2(statureM / 2 - camHeight, distance)
        let cp = cos(pitch), sp = sin(pitch)
        // A slight dilation of the mask that stays all recording, and per-edge noise.
        let dilation = off.contains("mask") ? 0 : shifted ? rng.range(-0.5, 3) : 0.5 + 0.8 * rng.gaussian()
        // The torso's own centre: the body turns about it.
        let torsoZ = model.parts.indices.filter { model.parts[$0] == .torso }.map { vertices[$0].z }
        let zc = (torsoZ.min()! + torsoZ.max()!) / 2

        // Turning as the app's users do (FilmedTurnValidationTests): 8–12 s, unevenly.
        let duration = shifted ? either((6, 8), (12, 16)) : rng.range(8, 12), wobble = 0.12 * rng.uniform(), phase = rng.uniform() * 2 * .pi
        let still = rng.range(0.3, 0.9), rest = 0.8
        var turn = TurnRecording()
        var widths: [BodyLevel: [[Double?]]] = [:]
        for level in Self.levels { widths[level] = Self.offsets.map { _ in [] } }
        var t = 0.0
        var swayX = 0.0, swayZ = 0.0
        var tops: [Double] = [], floors: [Double] = []
        while t <= still + duration + rest {
            let u = min(1, max(0, (t - still) / duration))
            let degrees = 360 * (u + wobble * sin(2 * .pi * u + phase) * sin(.pi * u) / (2 * .pi))
            let theta = Float(degrees * .pi / 180)
            // Standing on one spot, not perfectly: a centimetre of drift.
            if !off.contains("sway") { swayX = 0.9 * swayX + 0.003 * rng.gaussian(); swayZ = 0.9 * swayZ + 0.003 * rng.gaussian() }
            let ct = cos(theta), st = sin(theta)
            // Project every drawn vertex: turn about the torso centre, then the camera.
            var proj = [SIMD2<Float>](repeating: .zero, count: vertices.count)
            let cl = cos(lean), sl = sin(lean), cr = cos(roll), sr = sin(roll)
            for (i, q) in vertices.enumerated() {
                // Leaning about the ankles, forward or back.
                let p = lean == 0 ? q : Vec3(q.x, q.y * cl - (q.z - zc) * sl, zc + q.y * sl + (q.z - zc) * cl)
                let x = p.x, z = p.z - zc
                let wx = x * ct + z * st + Float(swayX), wz = -x * st + z * ct + Float(swayZ)
                // Camera at (0, camHeight, distance) looking along −z, pitched down.
                let cx = wx, cy = p.y - camHeight, cz = wz - distance
                let ry = cy * cp + cz * sp, rz = -cy * sp + cz * cp
                let u = focal * cx / -rz, v = -focal * ry / -rz
                // The phone held off level turns the picture about its centre.
                proj[i] = SIMD2(maskWidth / 2 + u * cr - v * sr, maskHeight / 2 + u * sr + v * cr)
            }
            // The top of the head (plus hair) and the soles, from the drawn outline.
            var top = Float.greatestFiniteMagnitude, floor = -Float.greatestFiniteMagnitude
            for (a, b, c) in drawn {
                for i in [a, b, c] { top = min(top, proj[i].y); floor = max(floor, proj[i].y) }
            }
            let headPx = (floor - top) / statureM
            top -= hair * headPx
            let personPx = Double(floor - top)
            tops.append(Double(top / maskHeight)); floors.append(Double(floor / maskHeight))
            // The body's centre column: the hips' centre, projected.
            let centre = Double(maskWidth / 2 + Float(swayX) * focal / distance)
            let outlier = !off.contains("mask") && rng.uniform() < 0.05 ? 1.05 + 0.1 * rng.uniform() : 1.0
            var levelWidths: [BodyLevel: Double] = [:]
            var profile: [BodyLevel: [Double?]] = [:]
            for level in Self.levels {
                for (k, offset) in Self.offsets.enumerated() {
                    let ratio = ratios[level]! + offset
                    let row = Double(top) + (1 - ratio) * personPx
                    var w = run(at: Float(row), centre: Float(centre), proj)
                    if var px = w {
                        px = off.contains("mask") ? px : (px + 2 * dilation + lopsided + edgeNoise * rng.gaussian()).rounded()
                        px *= outlier
                        w = px * heightCm / personPx
                    }
                    widths[level]![k].append(w)
                    profile[level, default: []].append(w)
                    if offset == 0, let w { levelWidths[level] = w }
                }
            }
            let span = max(0.27, abs(cos(degrees * .pi / 180))) + (off.contains("mask") ? 0 : 0.03 * rng.gaussian())
            // The frame's width profile down the torso, as the app reads it (no legs: the
            // silhouette fit then shapes the torso only).
            var stop: StopProfile?
            if stops {
                let torso = SilhouetteRows.torso.map { f -> Double? in
                    guard var px = run(at: top + Float(f) * Float(personPx), centre: Float(centre), proj) else { return nil }
                    if !off.contains("mask") { px = (px + 2 * dilation + edgeNoise * rng.gaussian()).rounded() }
                    return px * heightCm / personPx
                }
                stop = StopProfile(station: 0, torso: torso, legs: SilhouetteRows.thigh.map { _ in [] },
                                   legsOuter: SilhouetteRows.thigh.map { _ in nil })
            }
            turn.add(.init(time: t, spanRatio: span, widths: levelWidths, profile: profile,
                           top: Double(top / maskHeight), floor: Double(floor / maskHeight), stop: stop))
            t += 0.1
        }
        var rec = Recording(turn: turn, widths: widths, hairCm: Double(hair) * heightCm, distance: Double(distance),
                            cameraHeight: Double(camHeight))
        rec.topFraction = tops.sorted()[tops.count / 2]
        rec.floorFraction = floors.sorted()[floors.count / 2]
        return rec
    }

    /// The width in pixels of the silhouette's run through the centre column on a row:
    /// where the drawn triangles cross the row, merged where they touch.
    func run(at y: Float, centre: Float, _ p: [SIMD2<Float>]) -> Double? {
        var spans: [(Float, Float)] = []
        for (a, b, c) in drawn {
            let pa = p[a], pb = p[b], pc = p[c]
            let lo = min(pa.y, pb.y, pc.y), hi = max(pa.y, pb.y, pc.y)
            guard y >= lo, y <= hi, hi > lo else { continue }
            var xs: [Float] = []
            for (u, v) in [(pa, pb), (pb, pc), (pc, pa)] where (u.y - y) * (v.y - y) <= 0 && u.y != v.y {
                xs.append(u.x + (v.x - u.x) * (y - u.y) / (v.y - u.y))
            }
            guard let l = xs.min(), let r = xs.max() else { continue }
            spans.append((l, r))
        }
        guard !spans.isEmpty else { return nil }
        spans.sort { $0.0 < $1.0 }
        var merged: [(Float, Float)] = []
        for s in spans {
            if let last = merged.last, s.0 <= last.1 + 1 {
                merged[merged.count - 1].1 = max(last.1, s.1)
            } else {
                merged.append(s)
            }
        }
        let hit = merged.first { $0.0 <= centre && $0.1 >= centre }
            ?? merged.min { abs(($0.0 + $0.1) / 2 - centre) < abs(($1.0 + $1.1) / 2 - centre) }
        return hit.map { Double($0.1 - $0.0) }
    }
}
