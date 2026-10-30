import Foundation

/// How a part of a garment sits, for colouring it on the avatar: blue where it fits,
/// yellow where it's loose, red where it's too long, purple where it's tight, orange
/// where it's too short.
public enum FitTone: UInt8, Sendable, CaseIterable {
    case fits, loose, long, tight, short
}

extension Avatar {
    /// A line on the garment that says where it ends or joins, against where the body
    /// wants it: the shoulder seam against the shoulder point, a sleeve's end against
    /// the wrist, a top's hem against where a top of this kind usually ends, a trouser
    /// hem against the ankle, the waistband against the waist.
    public struct FitLine: Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case shoulderSeam, sleeveEnd, hem, waistband
        }

        public var kind: Kind
        public var tone: FitTone
        /// How far it is from where it should be, cm: + lower, longer or looser, − higher,
        /// shorter or tighter. 0 for a waistband (its tone says how it sits).
        public var deltaCm: Double
        /// Where it is on the draped garment, as segments: pairs of points.
        public var line: [Vec3]
        /// Where it should be, when that's elsewhere, as dashes: pairs of points.
        public var target: [Vec3]
        /// Where its label goes (on the avatar's left or front), and the outward direction there.
        public var anchor: Vec3
        public var normal: Vec3
    }
}

/// What `dress` decided about a garment's shape, for colouring it and drawing its lines.
struct GarmentShape {
    var fit: Avatar.GarmentFit
    /// Lowest edge of the body part (top) or of the legs (trousers), as cut.
    var hemY: Float
    /// Sleeve length along the arm, metres (tops).
    var sleeveReach: Float = 0
    var longSleeves = false
    /// How far the shoulder seam sits out from the shoulder point, metres per side.
    var dropped: Float = 0
}

extension BodyModel {
    /// Signed distance from arm `i`'s armhole: the plane through the shoulder point
    /// (acromion; biacromial breadth is `shoulderHalf / 1.08` each side of the middle)
    /// and the armpit, leaning in towards the armpit as an armhole does. Positive out
    /// towards the hand. A set-in sleeve's seam sits at 0; a dropped one further out.
    func armhole(_ i: Int, _ p: Vec3) -> Float {
        let side: Float = arms[i].dir.x > 0 ? 1 : -1
        let top = Vec3(side * shoulderHalf / 1.08, shoulderY, 0)
        let pit = Vec3(side * chest.0 * 0.92, armpitY - 0.01 * h, 0)
        let along = top - pit
        let n = Vec3(along.y * side, -along.x * side, 0).normalized
        return (p - top).dot(n)
    }

    /// Where a top of regular length ends: just below the hips.
    var regularHemY: Float { crotchY + 0.035 * h }

    // MARK: Tones

    /// Per vertex, how the garment sits there and how strongly. Tightness comes from the
    /// stretch the drape left (from 0.6 of what the fabric takes comfortably, where the
    /// zone report says "tight"); length from where the garment ends against the body;
    /// the shoulders from where the seam sits against the shoulder point; looseness from
    /// fabric standing further off the body than a regular fit's room (2.5 cm round the
    /// body, about 16 cm of ease; 3.2 cm round a trouser leg, about 20 cm). Tightness
    /// wins over the rest. Each vertex then takes the tone most of its neighbours have,
    /// so the map shows areas rather than speckles.
    func tones(_ shape: GarmentShape, rest: [Vec3], tags: [Int], stretch: [Float], contact: [Bool], gap: [Float],
               fabric: Fabric, neighbours: [[Int]]) -> (tones: [FitTone], weights: [Float]) {
        var tones = [FitTone](repeating: .fits, count: rest.count)
        var weights = [Float](repeating: 0, count: rest.count)
        let trousers: Bool = if case .trousers = shape.fit.kind { true } else { false }
        for i in rest.indices {
            let r = rest[i], tag = tags[i]
            let used = max(0, stretch[i] - 0.008) / fabric.stretchLimit
            if used >= 0.6, contact[i] {
                tones[i] = .tight
                weights[i] = min(1, 0.6 + (used - 0.6))
                continue
            }
            if let (tone, weight) = region(shape, r, tag) {
                tones[i] = tone
                weights[i] = weight
                continue
            }
            let room: Float = trousers && tag > 0 ? 3.2 : 2.5
            let g = gap[i] * 100
            if !contact[i], g > room {
                tones[i] = .loose
                weights[i] = min(1, 0.45 + (g - room) / 3)
            }
        }
        var smoothed = tones, smoothedWeights = weights
        for i in rest.indices where !neighbours[i].isEmpty {
            var count = [Int](repeating: 0, count: FitTone.allCases.count)
            count[Int(tones[i].rawValue)] += 2
            for j in neighbours[i] { count[Int(tones[j].rawValue)] += 1 }
            let best = count.indices.max { count[$0] < count[$1] }!
            smoothed[i] = FitTone(rawValue: UInt8(best))!
            var sum: Float = 0, n: Float = 0
            for j in neighbours[i] + [i] where tones[j] == smoothed[i] { sum += weights[j]; n += 1 }
            smoothedWeights[i] = smoothed[i] == .fits ? 0 : sum / max(1, n)
        }
        return (smoothed, smoothedWeights)
    }

    /// The length and shoulder verdicts that belong to a place on the garment, if any.
    private func region(_ shape: GarmentShape, _ r: Vec3, _ tag: Int) -> (FitTone, Float)? {
        let fit = shape.fit
        switch fit.kind {
        case .trousers:
            guard tag > 0 else { return nil }
            if fit.lengthDelta >= 1.5, r.y < ankleY + 0.005 { return (.long, 1) }
            if fit.lengthDelta <= -1.5, r.y < shape.hemY + 0.04 { return (.short, 0.85) }
            return nil
        case .top:
            if tag == 0 {
                if fit.lengthDelta >= 2, r.y < regularHemY { return (.long, min(1, 0.6 + (regularHemY - r.y) / 0.05)) }
                if fit.lengthDelta <= -2, r.y < shape.hemY + 0.04 { return (.short, 0.85) }
            }
            let i = r.x > 0 ? 0 : 1
            let arm = arms[i]
            let along = (r - arm.start).dot(arm.dir)
            if tag > 0, shape.longSleeves {
                if fit.sleeveDelta >= 1.5, along > armLength + 0.01 { return (.long, 1) }
                if fit.sleeveDelta <= -1.5, along > shape.sleeveReach - 0.04 { return (.short, 0.85) }
            }
            // Between the shoulder point and the seam: fabric hanging off the shoulder
            // (seam dropped) or a shoulder the garment doesn't reach (seam inside).
            guard r.y > armpitY - 0.02 * h, abs(shape.dropped) >= 0.008 else { return nil }
            let a = armhole(i, r)
            let lo = min(0, shape.dropped), hi = max(0, shape.dropped)
            guard a >= lo - 0.004, a <= hi + 0.004 else { return nil }
            return shape.dropped > 0 ? (.loose, 0.85) : (.tight, 0.85)
        }
    }

    // MARK: Lines

    func fitLines(_ shape: GarmentShape, mesh: Mesh, tags: [Int], cover: @escaping (Vec3) -> Float,
                  report: [FitZone: ZoneReport]) -> [Avatar.FitLine] {
        let fit = shape.fit
        var out: [Avatar.FitLine] = []
        func add(_ kind: Avatar.FitLine.Kind, tone: FitTone, delta: Double, line: [Vec3], target: [Vec3], towards: Vec3) {
            guard !line.isEmpty else { return }
            let dir = towards.normalized
            let anchor = line.max { $0.dot(dir) < $1.dot(dir) } ?? line[0]
            out.append(Avatar.FitLine(kind: kind, tone: tone, deltaCm: delta, line: line, target: target,
                                      anchor: anchor, normal: gradient({ distance($0) }, at: anchor)))
        }
        func tone(_ delta: Double, _ threshold: Double, over: FitTone, under: FitTone) -> FitTone {
            delta >= threshold ? over : delta <= -threshold ? under : .fits
        }
        switch fit.kind {
        case .trousers:
            let waistband = (waistY + hipY) / 2
            let waistTone: FitTone = switch report[.waist]?.tension {
            case .tight?, .veryTight?, .slightlyTight?: .tight
            case .loose?: .loose
            default: .fits
            }
            add(.waistband, tone: waistTone, delta: 0,
                line: contour({ $0.y - (waistband - 0.006) }, parts: [0], mesh: mesh, tags: tags),
                target: [], towards: Vec3(0.7, 0, 1))
            let t = tone(fit.lengthDelta, 1.5, over: .long, under: .short)
            let hems = mesh.positions.map(\.y).min() ?? 0
            var line: [Vec3] = [], target: [Vec3] = []
            for (i, leg) in legs.enumerated() {
                line += contour({ $0.y - (hems + 0.006) }, parts: [i + 1], mesh: mesh, tags: tags)
                if t != .fits {
                    target += ring(center: Vec3(leg.ankle.x, ankleY, leg.ankle.z), axis: Vec3(0, 1, 0), cover: cover)
                }
            }
            add(.hem, tone: t, delta: fit.lengthDelta, line: line, target: target, towards: Vec3(1, 0, 0.6))
        case .top:
            // Shoulder seams: half the width difference each side.
            let perSide = fit.shoulderDelta / 2
            let shoulderTone = tone(perSide, 1, over: .loose, under: .tight)
            var seam: [Vec3] = [], seamTarget: [Vec3] = []
            var cuff: [Vec3] = [], cuffTarget: [Vec3] = []
            let sleeveTone = shape.longSleeves ? tone(fit.sleeveDelta, 1.5, over: .long, under: .short) : .fits
            for (i, arm) in arms.enumerated() {
                let dir = arm.dir, dropped = shape.dropped
                let pit = armpitY - 0.02 * h
                seam += contour({ p in p.y > pit ? self.armhole(i, p) - dropped : .nan },
                                parts: [0, i + 1], mesh: mesh, tags: tags)
                if shoulderTone != .fits {
                    // Where the seam belongs, dashed on the fabric over the shoulder point.
                    seamTarget += contour({ p in p.y > pit ? self.armhole(i, p) : .nan }, parts: [0, i + 1],
                                          mesh: mesh, tags: tags, dash: { $0.y + $0.z })
                }
                var end: Float = -1
                for v in mesh.positions.indices where tags[v] == i + 1 { end = max(end, mesh.positions[v].dot(dir)) }
                cuff += contour({ $0.dot(dir) - (end - 0.005) }, parts: [i + 1], mesh: mesh, tags: tags)
                if sleeveTone != .fits {
                    cuffTarget += ring(center: arm.start + dir * armLength, axis: dir, cover: cover)
                }
            }
            add(.shoulderSeam, tone: shoulderTone, delta: perSide, line: seam, target: seamTarget, towards: Vec3(1, 0.3, 0.4))
            add(.sleeveEnd, tone: sleeveTone, delta: shape.longSleeves ? fit.sleeveDelta : 0, line: cuff, target: cuffTarget,
                towards: Vec3(1, -0.3, 0.5))
            let hemTone = tone(fit.lengthDelta, 2, over: .long, under: .short)
            let hem = mesh.positions.indices.filter { tags[$0] == 0 }.map { mesh.positions[$0].y }.min() ?? 0
            add(.hem, tone: hemTone, delta: fit.lengthDelta,
                line: contour({ $0.y - (hem + 0.006) }, parts: [0], mesh: mesh, tags: tags),
                target: hemTone == .fits ? [] : ring(center: Vec3(0, regularHemY, torso.ring(at: regularHemY).center.z),
                                                     axis: Vec3(0, 1, 0), cover: cover),
                towards: Vec3(0.6, 0, 1))
        }
        return out
    }

    /// Where a function over the garment's surface crosses zero, on the triangles of the
    /// given parts, as segments slightly off the fabric; with `dash`, only every other
    /// 8 mm along it. Where `f` is NaN the line doesn't run.
    func contour(_ f: (Vec3) -> Float, parts: Set<Int>, mesh: Mesh, tags: [Int], dash: ((Vec3) -> Float)? = nil) -> [Vec3] {
        var out: [Vec3] = []
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let ids = [Int(mesh.indices[t]), Int(mesh.indices[t + 1]), Int(mesh.indices[t + 2])]
            guard ids.allSatisfy({ parts.contains(tags[$0]) }) else { continue }
            let v = ids.map { f(mesh.positions[$0]) }
            guard !v.contains(where: \.isNaN) else { continue }
            var cross: [Vec3] = []
            for e in 0..<3 {
                let a = e, b = (e + 1) % 3
                guard (v[a] < 0) != (v[b] < 0) else { continue }
                let s = v[a] / (v[a] - v[b])
                let pa = mesh.positions[ids[a]] + mesh.normals[ids[a]] * 0.0018
                let pb = mesh.positions[ids[b]] + mesh.normals[ids[b]] * 0.0018
                cross.append(pa + (pb - pa) * s)
            }
            guard cross.count == 2 else { continue }
            if let dash {
                let middle = (cross[0] + cross[1]) * 0.5
                guard Int((dash(middle) / 0.008).rounded(.down)) % 2 == 0 else { continue }
            }
            out += cross
        }
        return out
    }

    /// A dashed ring round `axis` through `center`, each point pushed out from the axis
    /// until it's outside the body and the garment (`cover`), so it shows on the fabric
    /// where the garment covers that place and on the skin where it doesn't.
    func ring(center: Vec3, axis: Vec3, cover: (Vec3) -> Float, only: (Vec3) -> Bool = { _ in true }) -> [Vec3] {
        let a = axis.normalized
        let helper = abs(a.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let u = a.cross(helper).normalized, w = a.cross(u)
        let count = 64
        var points: [Vec3?] = []
        for k in 0..<count {
            let theta = Float(k) / Float(count) * 2 * .pi
            let out = u * cos(theta) + w * sin(theta)
            guard only(out) else { points.append(nil); continue }
            var p = center + out * 0.01
            var outside = false
            for _ in 0..<160 {
                if distance(p) > 0, cover(p) > 0 { outside = true; break }
                p = p + out * 0.002
            }
            points.append(outside ? p + out * 0.0025 : nil)
        }
        var dashes: [Vec3] = []
        for k in stride(from: 0, to: count, by: 2) {
            if let p = points[k], let q = points[(k + 1) % count] { dashes += [p, q] }
        }
        return dashes
    }

    // MARK: Sway

    /// How freely each vertex swings when the body turns: nothing where the garment hangs
    /// from, rising with the distance it hangs below that (and along a sleeve), more where
    /// it stands off the body and for fluid fabric.
    func sway(_ shape: GarmentShape, rest: [Vec3], tags: [Int], gap: [Float], pinnedAbove: Float, fabric: Fabric) -> [Float] {
        rest.indices.map { i in
            let r = rest[i]
            var hang = max(0, pinnedAbove - r.y) / 0.35
            if case .top = shape.fit.kind, tags[i] > 0 {
                let arm = arms[r.x > 0 ? 0 : 1]
                hang = max(0, (r - arm.start).dot(arm.dir)) / armLength * 0.8
            }
            let loose = min(1, (gap[i] * 100 + 0.5) / 4)
            return min(1, min(1, hang) * (0.25 + 0.75 * loose) * (1.25 - fabric.drape))
        }
    }
}
