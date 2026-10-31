import Foundation

extension BodyModel {
    /// The body from the SOMA shape model fitted to the measurements: its skin is what's
    /// shown, and the distance field the garments are cut from and collide with is taken
    /// from it: the torso as level outlines of the skin every centimetre or so, arms and
    /// legs as tapered capsules through the joint seams, as wide as the skin round them.
    init(soma model: SomaModel, _ m: Avatar.Measurements) {
        var v = model.vertices(model.coefficients(for: m.somaTarget))
        let floor = v.map(\.y).min() ?? 0
        v = v.map { Vec3($0.x, $0.y - floor, $0.z) }
        let pts = model.points, rings = model.rings
        self.m = m
        let h = v[pts.top].y
        self.h = h
        let crotchY = v[pts.crotch].y
        let neckRing = rings.neck.map { v[$0] }
        // The seam between the neck and the torso runs low at the front (the notch at the
        // top of the breastbone) and high at the back (the bone at the base of the neck).
        let front = neckRing.max { $0.z < $1.z } ?? Vec3(0, 0.82 * h, 0.05)
        let back = neckRing.min { $0.z < $1.z } ?? Vec3(0, 0.85 * h, -0.05)
        let neckY = (front.y + back.y) / 2
        self.crotchY = crotchY
        hipY = v[pts.buttock].y
        waistY = v[pts.navel].y
        chestY = v[pts.nipple].y
        armpitY = rings.shoulder[0].map { v[$0].y }.min() ?? 0.75 * h
        shoulderY = v[pts.acromion[0]].y
        self.neckY = neckY
        kneeY = model.centroid(rings.knee[0], v).y
        ankleY = model.centroid(rings.ankle[0], v).y

        // A crew neck: about 1.5 cm below the notch at the front, just below the bone at
        // the back, straight across.
        let lowFront = front - Vec3(0, 0.009 * h, 0), lowBack = back - Vec3(0, 0.004 * h, 0)
        let normal = Vec3(0, lowFront.z - lowBack.z, lowBack.y - lowFront.y).normalized
        neckline = (normal, normal.dot(lowFront))
        necklineTop = lowBack.y
        skinMargin = 0.006
        let sections = Self.outlines(model, v, from: crotchY + 0.003 * h, to: back.y, crotchY: crotchY,
                                     neckFrom: front.y, h: h)
        let torso = LoftedTorso(rings: sections)
        self.torso = torso
        func size(at y: Float) -> (Float, Float) { let r = torso.ring(at: y); return (r.halfWidth, r.halfDepth) }
        hip = size(at: v[pts.buttock].y)
        waist = size(at: v[pts.navel].y)
        chest = size(at: v[pts.nipple].y)

        let arms = (0..<2).map { Self.arm($0, model, v, h: h) }
        self.arms = arms.map { ($0.start, $0.dir, $0.limb, $0.hand) }
        armLength = arms[0].length
        upperArmR = arms[0].upperRadius
        // The armhole plane runs through the shoulder point at shoulderHalf / 1.08.
        shoulderHalf = abs(v[pts.acromion[0]].x) * 1.08

        let thighPoints = model.slice(v, at: crotchY - 0.018 * h, parts: [.leftLeg])
        let thighR = SomaModel.hullPerimeter(thighPoints) / (2 * .pi)
        self.thighR = thighR
        legX = thighPoints.isEmpty ? 0.05 * h : thighPoints.map(\.0).reduce(0, +) / Float(thighPoints.count)
        legs = (0..<2).map { Self.leg($0, model, v, h: h, crotchY: crotchY, thighR: thighR) }

        // Neck and head, for the distance field only: the skin shows the real ones.
        let neckCenter = Self.mean(neckRing)
        let neckR = neckRing.map { Vec3($0.x - neckCenter.x, 0, $0.z - neckCenter.z).length }.reduce(0, +) / Float(max(1, neckRing.count))
        let head = v.indices.filter { model.parts[$0] == .head && v[$0].y > neckCenter.y + 0.04 * h }.map { v[$0] }
        let (headLo, headHi) = Self.box(head)
        let headCenter = Vec3(0, (headLo.y + h) / 2, (headLo.z + headHi.z) / 2)
        headY = headCenter.y
        neck = Bone(a: Vec3(0, neckY - 0.02 * h, neckCenter.z), b: Vec3(0, headCenter.y - 0.04 * h, neckCenter.z),
                    ra: neckR, rb: neckR * 0.95)
        skull = Ellipsoid(center: headCenter, radii: Vec3(max(0.05, (headHi.x - headLo.x) / 2), max(0.06, (h - headLo.y) / 2),
                                                          max(0.06, (headHi.z - headLo.z) / 2)))
        jaw = Ellipsoid(center: headCenter + Vec3(0, -0.035 * h, 0.01 * h), radii: Vec3(0.03 * h, 0.03 * h, 0.035 * h))

        var skin = Mesh()
        skin.positions = v
        skin.indices = model.triangles
        skin.computeNormals()
        surface = skin
        let (lo, hi) = Self.box(v)
        bounds = (Vec3(lo.x - 0.02, -0.01, lo.z - 0.02), Vec3(hi.x + 0.02, h + 0.01, hi.z + 0.02))
    }

    static func mean(_ points: [Vec3]) -> Vec3 {
        points.reduce(Vec3(0, 0, 0)) { $0 + $1 } * (1 / Float(max(1, points.count)))
    }

    static func box(_ points: [Vec3]) -> (Vec3, Vec3) {
        guard let first = points.first else { return (Vec3(0, 0, 0), Vec3(0, 0, 0)) }
        var lo = first, hi = first
        for p in points {
            lo = Vec3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = Vec3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return (lo, hi)
    }

    /// The torso's level outlines, about every 1.2 cm, as radii round the middle of each
    /// (the furthest skin in each direction), filled in where the cut found nothing.
    /// Above `neckFrom` the neck is part of it, so the top narrows to the neck.
    static func outlines(_ model: SomaModel, _ v: [Vec3], from low: Float, to top: Float, crotchY: Float, neckFrom: Float,
                         h: Float) -> [Ring] {
        let bins = 48
        let withNeck = SomaModel.girthParts.union([.head])
        func outline(_ y: Float) -> Ring? {
            let keep: Set<SomaModel.Part> = y > neckFrom ? withNeck : y > crotchY + 0.004 * h ? SomaModel.girthParts : [.torso]
            let points = model.slice(v, at: y, parts: keep, touching: y > crotchY + 0.004 * h)
            guard points.count >= 6 else { return nil }
            var x1: Float = 0, z0 = Float.greatestFiniteMagnitude, z1 = -Float.greatestFiniteMagnitude
            for (x, z) in points { x1 = max(x1, abs(x)); z0 = min(z0, z); z1 = max(z1, z) }
            let center = Vec3(0, y, (z0 + z1) / 2)
            var radii = [Float](repeating: -1, count: bins)
            for (x, z) in points {
                let dz = z - center.z
                var a = atan2(dz, x)
                if a < 0 { a += 2 * .pi }
                let i = min(bins - 1, Int(a / (2 * .pi) * Float(bins)))
                radii[i] = max(radii[i], (x * x + dz * dz).squareRoot())
            }
            let filled = radii.indices.filter { radii[$0] > 0 }
            guard filled.count >= 4, let first = filled.first, let last = filled.last else { return nil }
            for i in radii.indices where radii[i] < 0 {
                let prev = filled.last { $0 < i } ?? last
                let next = filled.first { $0 > i } ?? first
                let span = (next - prev + bins) % bins
                let f = Float((i - prev + bins) % bins) / Float(max(1, span))
                radii[i] = radii[prev] + (radii[next] - radii[prev]) * f
            }
            return Ring(center: center, halfWidth: x1, halfDepth: (z1 - z0) / 2, power: 2, radii: radii)
        }
        let count = max(8, Int((top - low) / 0.012))
        return (0...count).compactMap { outline(low + (top - low) * Float($0) / Float(count)) }
    }

    /// The cross-section of these parts in a slab through `a` across `d`: the smallest
    /// circle round the skin there, on the plane through `a`, so a capsule through its
    /// centre covers the skin without standing off it more than it must.
    static func section(_ model: SomaModel, _ v: [Vec3], around a: Vec3, _ d: Vec3, parts keep: Set<SomaModel.Part>,
                        slab: Float) -> (center: Vec3, radius: Float)? {
        let u = (abs(d.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)).cross(d).normalized
        let w = d.cross(u)
        var flat: [(Float, Float)] = []
        for i in v.indices where keep.contains(model.parts[i]) {
            let q = v[i] - a
            if abs(q.dot(d)) < slab { flat.append((q.dot(u), q.dot(w))) }
        }
        guard flat.count >= 4, let (cx, cy, r) = enclosingCircle(flat) else { return nil }
        return (a + u * cx + w * cy, r)
    }

    /// The smallest circle containing all the points: tried through every pair (as a
    /// diameter) and every triple, smallest that covers them all (few points per slab).
    static func enclosingCircle(_ p: [(Float, Float)]) -> (Float, Float, Float)? {
        func covers(_ c: (Float, Float, Float)) -> Bool {
            p.allSatisfy { ($0.0 - c.0) * ($0.0 - c.0) + ($0.1 - c.1) * ($0.1 - c.1) <= c.2 * c.2 * 1.0001 + 1e-10 }
        }
        var best: (Float, Float, Float)?
        func consider(_ c: (Float, Float, Float)) {
            if c.2 < (best?.2 ?? .greatestFiniteMagnitude), covers(c) { best = c }
        }
        let n = p.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                let cx = (p[i].0 + p[j].0) / 2, cy = (p[i].1 + p[j].1) / 2
                consider((cx, cy, ((p[i].0 - cx) * (p[i].0 - cx) + (p[i].1 - cy) * (p[i].1 - cy)).squareRoot()))
                for k in (j + 1)..<n {
                    let (ax, ay) = p[i], (bx, by) = p[j], (qx, qy) = p[k]
                    let dd = 2 * (ax * (by - qy) + bx * (qy - ay) + qx * (ay - by))
                    guard abs(dd) > 1e-12 else { continue }
                    let a2 = ax * ax + ay * ay, b2 = bx * bx + by * by, q2 = qx * qx + qy * qy
                    let ux = (a2 * (by - qy) + b2 * (qy - ay) + q2 * (ay - by)) / dd
                    let uy = (a2 * (qx - bx) + b2 * (ax - qx) + q2 * (bx - ax)) / dd
                    consider((ux, uy, ((ax - ux) * (ax - ux) + (ay - uy) * (ay - uy)).squareRoot()))
                }
            }
        }
        return best
    }

    /// Arm `i` (0 left): from the seam at the shoulder over the elbow to the wrist.
    static func arm(_ i: Int, _ model: SomaModel, _ v: [Vec3], h: Float)
        -> (start: Vec3, dir: Vec3, limb: Limb, hand: Ellipsoid, length: Float, upperRadius: Float) {
        let rings = model.rings
        let keep: Set<SomaModel.Part> = i == 0 ? [.leftArm, .leftHand] : [.rightArm, .rightHand]
        let start = model.centroid(rings.shoulder[i], v)
        let elbow = model.centroid(rings.elbow[i], v), wrist = model.centroid(rings.wrist[i], v)
        let dir = (wrist - start).normalized
        let upperShare = (elbow - start).length / max(1e-4, (elbow - start).length + (wrist - elbow).length)
        func path(_ f: Float) -> Vec3 {
            f <= upperShare ? start + (elbow - start) * (f / upperShare)
                : elbow + (wrist - elbow) * ((f - upperShare) / max(1e-4, 1 - upperShare))
        }
        let fractions: [Float] = [0.04] + (1...16).map { Float($0) / 16 }
        var centers: [Vec3] = [], radii: [Float] = []
        var last: Float = 0.028 * h
        for f in fractions {
            let axis = f <= upperShare ? (elbow - start).normalized : (wrist - elbow).normalized
            let s = section(model, v, around: path(f), axis, parts: keep, slab: 0.012)
            centers.append(f > 0.9 ? path(f) : s?.center ?? path(f))
            radii.append(s?.radius ?? last); last = radii[radii.count - 1]
        }
        var bones = (0..<(fractions.count - 1)).map { j in
            Bone(a: centers[j], b: centers[j + 1], ra: radii[j], rb: radii[j + 1])
        }
        bones[0].a = start
        let hand = v.indices.filter { model.parts[$0] == (i == 0 ? .leftHand : .rightHand) }.map { v[$0] }
        let center = mean(hand)
        let across = Vec3(dir.y, -dir.x, 0)
        func extent(_ axis: Vec3) -> Float { hand.map { abs(($0 - center).dot(axis)) }.max() ?? 0.03 }
        let handShape = Ellipsoid(center: center,
                                  radii: Vec3(max(0.008, extent(across) * 0.8), max(0.03, extent(dir)), max(0.015, extent(Vec3(0, 0, 1)) * 0.85)),
                                  frame: (across, dir, Vec3(0, 0, 1)))
        return (start, dir, Limb(bones: bones, blend: 0), handShape, (wrist - start).length, radii[2])
    }

    /// Leg `i` (0 left): from the seam at the groin through the knee to the ankle.
    static func leg(_ i: Int, _ model: SomaModel, _ v: [Vec3], h: Float, crotchY: Float, thighR: Float)
        -> (hip: Vec3, knee: Vec3, ankle: Vec3, limb: Limb, foot: Ellipsoid) {
        let rings = model.rings
        let keep: Set<SomaModel.Part> = i == 0 ? [.leftLeg] : [.rightLeg]
        let groin = model.centroid(rings.groin[i], v)
        let knee = model.centroid(rings.knee[i], v), ankle = model.centroid(rings.ankle[i], v)
        let top = Vec3(groin.x, max(groin.y, crotchY + 0.02 * h), groin.z)
        // Every ~5% of the way, thigh then shin; the knee is the 9th point.
        let points = (0..<9).map { top + (knee - top) * (Float($0) / 8) } + (1...8).map { knee + (ankle - knee) * (Float($0) / 8) }
        var centers: [Vec3] = [], radii: [Float] = []
        var last = thighR
        for (j, p) in points.enumerated() {
            let d = j < 8 ? (knee - top).normalized : (ankle - knee).normalized
            let s = j == 0 ? nil : section(model, v, around: p, d, parts: keep, slab: 0.014)
            var r = s?.radius ?? last
            // At the groin the slab takes in the seat; the thigh itself is narrower.
            if j < 2 { r = min(r, thighR * (j == 0 ? 0.9 : 1.05)) }
            centers.append(j == 0 || j == points.count - 1 ? p : s?.center ?? p)
            radii.append(r); last = r
        }
        let bones = (0..<(points.count - 1)).map { Bone(a: centers[$0], b: centers[$0 + 1], ra: radii[$0], rb: radii[$0 + 1]) }
        let foot = v.indices.filter { model.parts[$0] == (i == 0 ? .leftFoot : .rightFoot) }.map { v[$0] }
        let (lo, hi) = box(foot)
        let footShape = Ellipsoid(center: (lo + hi) * 0.5,
                                  radii: Vec3(max(0.02, (hi.x - lo.x) / 2), max(0.02, (hi.y - lo.y) / 2), max(0.05, (hi.z - lo.z) / 2)))
        return (top, knee, ankle, Limb(bones: bones, blend: 0), footShape)
    }
}
