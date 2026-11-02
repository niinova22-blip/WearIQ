import Foundation

/// The body shape model from NVIDIA SOMA-X (https://github.com/NVlabs/SOMA-X,
/// Apache-2.0; licence in Resources/SOMA-X-LICENSE.txt): a PCA of 9,326 SizeUSA scans,
/// 303 Triplegangers scans and GarmentMeasurements, here its 4,505-vertex mesh and first
/// 32 components, written by scripts/build_soma_body.py. A body is the mean plus a
/// weighted sum of the components; the weights are found from the eight measurements
/// the app has, through a linear model of how each component moves them (fitted on
/// 6,000 sampled bodies; held-out bodies come back within about half a centimetre).
///
/// The measurements are taken on the mesh as a tape would: girths are the convex
/// outline of a level cut, at the nipples (chest), the navel (waist), the furthest
/// point of the buttocks (hip) and just below the crotch (thigh, both legs averaged);
/// the shoulder runs between the tops of the shoulders and the arm from there over the
/// elbow to the wrist (both arms averaged), both scaled to the ANSUR II bone measures.
/// The script measures the same way.
struct SomaModel: Sendable {
    enum Part: UInt8 {
        case torso = 0, head, leftArm, rightArm, leftLeg, rightLeg, leftHand, rightHand, leftFoot, rightFoot
    }

    /// Landmark vertices.
    struct Points: Sendable {
        var crotch, navel, nipple, buttock, top: Int
        var acromion: [Int]
    }

    /// Vertices along the seam between two parts, left side first where there are two.
    struct Rings: Sendable {
        var shoulder, elbow, wrist, groin, knee, ankle: [[Int]]
        var neck: [Int]
    }

    let mean: [Vec3]
    /// Component k of vertex i, already scaled to one standard deviation, at k·V + i.
    let dirs: [Vec3]
    let triangles: [UInt32]
    let parts: [Part]
    let points: Points
    let rings: Rings
    let components: Int
    /// measurements ≈ m0 + B·c, row-major M×K, cm.
    let m0: [Double]
    let b: [Double]
    let residualSD: [Double]
    let calibration: [Double]

    static let measurementCount = 8

    /// The bundled model; nil if it can't be read.
    static let shared: SomaModel? = {
        guard let url = Bundle.module.url(forResource: "SomaBody", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        return SomaModel(data: data)
    }()

    init?(data: Data) {
        var at = 0
        func u32() -> Int? {
            guard at + 4 <= data.count else { return nil }
            defer { at += 4 }
            return Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }.littleEndian)
        }
        func f32s(_ n: Int) -> [Float]? {
            guard at + 4 * n <= data.count else { return nil }
            defer { at += 4 * n }
            return data.withUnsafeBytes { raw in
                (0..<n).map { Float(bitPattern: raw.loadUnaligned(fromByteOffset: at + 4 * $0, as: UInt32.self).littleEndian) }
            }
        }
        guard data.count > 28, data.prefix(4) == Data("SOMA".utf8) else { return nil }
        at = 4
        guard u32() == 1, let v = u32(), let t = u32(), let k = u32(), let m = u32(), let ringCount = u32(),
              m == Self.measurementCount, ringCount == 13 else { return nil }
        guard let meanF = f32s(v * 3), let scale = f32s(k) else { return nil }
        mean = (0..<v).map { Vec3(meanF[3 * $0], meanF[3 * $0 + 1], meanF[3 * $0 + 2]) }
        guard at + 2 * k * v * 3 <= data.count else { return nil }
        let start = at
        dirs = data.withUnsafeBytes { raw in
            (0..<(k * v)).map { j in
                let c = Float(scale[j / v])
                func q(_ e: Int) -> Float {
                    Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: start + 2 * (3 * j + e), as: Int16.self))) * c
                }
                return Vec3(q(0), q(1), q(2))
            }
        }
        at += 2 * k * v * 3
        guard at + 2 * t * 3 + v <= data.count else { return nil }
        let triStart = at
        triangles = data.withUnsafeBytes { raw in
            (0..<(t * 3)).map { UInt32(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: triStart + 2 * $0, as: UInt16.self))) }
        }
        at += 2 * t * 3
        parts = data[data.startIndex + at ..< data.startIndex + at + v].map { Part(rawValue: $0) ?? .torso }
        at += v
        var marks: [Int] = []
        for _ in 0..<7 { guard let i = u32() else { return nil }; marks.append(i) }
        points = Points(crotch: marks[0], navel: marks[1], nipple: marks[2], buttock: marks[3], top: marks[4],
                        acromion: [marks[5], marks[6]])
        var lists: [[Int]] = []
        for _ in 0..<ringCount {
            guard let n = u32() else { return nil }
            var list: [Int] = []
            for _ in 0..<n { guard let i = u32() else { return nil }; list.append(i) }
            lists.append(list)
        }
        rings = Rings(shoulder: [lists[0], lists[1]], elbow: [lists[2], lists[3]], wrist: [lists[4], lists[5]],
                      groin: [lists[6], lists[7]], knee: [lists[8], lists[9]], ankle: [lists[10], lists[11]],
                      neck: lists[12])
        guard let m0F = f32s(m), let bF = f32s(m * k), let sdF = f32s(m), let calF = f32s(m) else { return nil }
        components = k
        m0 = m0F.map(Double.init); b = bF.map(Double.init)
        residualSD = sdF.map(Double.init); calibration = calF.map(Double.init)
        let all = [marks, lists.flatMap { $0 }].flatMap { $0 }
        guard all.allSatisfy({ $0 < v }), triangles.allSatisfy({ Int($0) < v }) else { return nil }
    }

    // MARK: Shape

    /// The body for these coefficients (standard deviations per component).
    func vertices(_ c: [Double]) -> [Vec3] {
        var out = mean
        let v = mean.count
        for k in 0..<min(components, c.count) where c[k] != 0 {
            let w = Float(c[k])
            for i in 0..<v { out[i] = out[i] + dirs[k * v + i] * w }
        }
        return out
    }

    /// The most likely body with these measurements (cm, in `Avatar.Measurements`
    /// order): least squares through the linear model, each measurement weighted by how
    /// well the model predicts it, with every component pulled towards the average body,
    /// then corrected twice against the body it gives. Components stay within ±3.5 SD,
    /// so impossible combinations come back as the nearest plausible body.
    func coefficients(for target: [Double], bust: Double? = nil) -> [Double] {
        let k = components, m = Self.measurementCount
        let w = residualSD.map { 1 / pow(max($0, 0.4), 2) }
        // The bust, when asked for, as one more row: linear about the average body.
        let bustRow: (b0: Double, g: [Double])? = bust.map { _ in
            let b0 = self.bust(mean)
            return (b0, (0..<k).map { j in
                var c = [Double](repeating: 0, count: k)
                c[j] = 1
                return self.bust(vertices(c)) - b0
            })
        }
        let wb = 1 / (1.5 * 1.5)
        // Normal equations (Bᵀ W B + I) c = Bᵀ W (t − m0).
        var a = [Double](repeating: 0, count: k * k)
        for i in 0..<k {
            a[i * k + i] = 1
            for j in 0..<k {
                var s = 0.0
                for r in 0..<m { s += b[r * k + i] * w[r] * b[r * k + j] }
                if let row = bustRow { s += row.g[i] * wb * row.g[j] }
                a[i * k + j] += s
            }
        }
        func solve(_ goal: [Double], _ bustGoal: Double?) -> [Double] {
            var rhs = [Double](repeating: 0, count: k)
            for i in 0..<k { for r in 0..<m { rhs[i] += b[r * k + i] * w[r] * (goal[r] - m0[r]) } }
            if let row = bustRow, let bustGoal {
                for i in 0..<k { rhs[i] += row.g[i] * wb * (bustGoal - row.b0) }
            }
            return Self.choleskySolve(a, rhs, k).map { max(-3.5, min(3.5, $0)) }
        }
        var goal = target
        var bustGoal = bust
        var c = solve(goal, bustGoal)
        for _ in 0..<2 {
            let v = vertices(c)
            let got = measure(v)
            for r in 0..<m { goal[r] += target[r] - got[r] }
            if let bust, let g = bustGoal { bustGoal = g + bust - self.bust(v) }
            c = solve(goal, bustGoal)
        }
        return c
    }

    /// The body for these measurements: the shape model's most likely body, then its
    /// girths brought to the asked ones where the model can't reach them.
    ///
    /// Thirty-two components at most ±3.5 SD cover most people but not all: a woman
    /// with a 160 cm waist (BMI 50+, about 1 in 30 US women in NHANES 2017–2020) came back
    /// 20 cm slimmer, and so would every garment drawn on her. Where the model falls
    /// short, the torso is widened (or narrowed) level by level about its own centre, by
    /// the ratio asked ÷ built at the chest, the navel and the seat, blended between them
    /// and back to nothing at the shoulder tops; the legs about their own centres by the
    /// thigh's ratio, half of it left at the knee and none at the ankle; the arms move
    /// out with the chest's side so they don't sink into it. A convex outline scaled about
    /// any point scales its perimeter by the same factor, so three passes settle it.
    func body(for target: [Double], bust: Double? = nil) -> [Vec3] {
        var v = vertices(coefficients(for: target, bust: bust))
        for _ in 0..<3 {
            let got = measure(v)
            let ratios = (1...4).map { max(0.75, min(1.35, target[$0] / max(got[$0], 1))) }
            guard ratios.contains(where: { abs($0 - 1) > 0.004 }) else { break }
            v = reshaped(v, chest: Float(ratios[0]), waist: Float(ratios[1]), hip: Float(ratios[2]), thigh: Float(ratios[3]))
        }
        return v
    }

    private func reshaped(_ v: [Vec3], chest rc: Float, waist rw: Float, hip rh: Float, thigh rt: Float) -> [Vec3] {
        let yChest = v[points.nipple].y, yWaist = v[points.navel].y, yHip = v[points.buttock].y
        let yCrotch = v[points.crotch].y
        let yTop = min(v[points.acromion[0]].y, v[points.acromion[1]].y)
        let floor = v.map(\.y).min() ?? 0
        let height = v[points.top].y - floor
        let yThigh = yCrotch - 0.018 * height
        // Each level's centre and half width (the torso's outline there).
        func frame(_ y: Float) -> (z: Float, half: Float) {
            let s = slice(v, at: y, parts: [.torso])
            guard let x0 = s.map(\.0).min(), let x1 = s.map(\.0).max(),
                  let z0 = s.map(\.1).min(), let z1 = s.map(\.1).max() else { return (0, 0) }
            return ((z0 + z1) / 2, (x1 - x0) / 2)
        }
        let fc = frame(yChest), fw = frame(yWaist), fh = frame(yHip)
        func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * max(0, min(1, t)) }
        // Torso ratio and centre by height.
        func torso(_ y: Float) -> (r: Float, z: Float) {
            if y >= yChest { return (lerp(rc, 1, (y - yChest) / max(yTop - yChest, 1e-4)), fc.z) }
            if y >= yWaist {
                let t = (yChest - y) / max(yChest - yWaist, 1e-4)
                return (lerp(rc, rw, t), lerp(fc.z, fw.z, t))
            }
            if y >= yHip {
                let t = (yWaist - y) / max(yWaist - yHip, 1e-4)
                return (lerp(rw, rh, t), lerp(fw.z, fh.z, t))
            }
            return (rh, fh.z)
        }
        // Each leg's centre at the thigh, the knee and the ankle.
        func legCentre(_ side: Int, _ y: Float) -> (Float, Float) {
            let kneeC = centroid(rings.knee[side], v), ankleC = centroid(rings.ankle[side], v)
            let s = slice(v, at: yThigh, parts: [side == 0 ? .leftLeg : .rightLeg])
            let tx = s.isEmpty ? kneeC.x : (s.map(\.0).min()! + s.map(\.0).max()!) / 2
            let tz = s.isEmpty ? kneeC.z : (s.map(\.1).min()! + s.map(\.1).max()!) / 2
            if y >= kneeC.y {
                let t = (yThigh - y) / max(yThigh - kneeC.y, 1e-4)
                return (lerp(tx, kneeC.x, t), lerp(tz, kneeC.z, t))
            }
            let t = (kneeC.y - y) / max(kneeC.y - ankleC.y, 1e-4)
            return (lerp(kneeC.x, ankleC.x, t), lerp(kneeC.z, ankleC.z, t))
        }
        let kneeY = (centroid(rings.knee[0], v).y + centroid(rings.knee[1], v).y) / 2
        let ankleY = (centroid(rings.ankle[0], v).y + centroid(rings.ankle[1], v).y) / 2
        func legRatio(_ y: Float) -> Float {
            if y >= yThigh { return rt }
            if y >= kneeY { return lerp(rt, 1 + (rt - 1) / 2, (yThigh - y) / max(yThigh - kneeY, 1e-4)) }
            return lerp(1 + (rt - 1) / 2, 1, (kneeY - y) / max(kneeY - ankleY, 1e-4))
        }
        // How far the chest's side moves out: the arms go with it.
        let armShift = (rc - 1) * fc.half
        let armpitY = rings.shoulder[0].map { v[$0].y }.min() ?? yChest
        var out = v
        for i in v.indices {
            let p = v[i]
            switch parts[i] {
            case .torso:
                let (r, z) = torso(p.y)
                out[i] = Vec3(p.x * r, p.y, z + (p.z - z) * r)
            case .leftLeg, .rightLeg:
                let (r, z) = torso(p.y)
                let upper = Vec3(p.x * r, p.y, z + (p.z - z) * r)
                let (cx, cz) = legCentre(parts[i] == .leftLeg ? 0 : 1, p.y)
                let lr = legRatio(p.y)
                let lower = Vec3(cx + (p.x - cx) * lr, p.y, cz + (p.z - cz) * lr)
                // Over the seat the leg is part of the hip's outline; below the thigh its own.
                out[i] = p.y >= yCrotch ? upper : p.y <= yThigh ? lower
                    : upper + (lower - upper) * ((yCrotch - p.y) / max(yCrotch - yThigh, 1e-4))
            case .leftArm, .rightArm, .leftHand, .rightHand:
                let w = max(0, min(1, (yTop - p.y) / max(yTop - armpitY, 1e-4)))
                out[i] = Vec3(p.x + (p.x > 0 ? 1 : -1) * armShift * w, p.y, p.z)
            default:
                break
            }
        }
        return out
    }

    /// The usual bust (`bust(_:)`, chest minus underbust, cm): a man's chest is little
    /// more than his ribcage, a woman's is about a B to C cup over it. On the shape
    /// model's own measure, whose average body sits at 11 cm with a spread of about 3.
    static func typicalBust(female: Bool, chest: Double) -> Double {
        female ? min(20, max(13, 15 + 0.08 * (chest - 90))) : 8
    }

    static func choleskySolve(_ a: [Double], _ b: [Double], _ n: Int) -> [Double] {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = a[i * n + j]
                for p in 0..<j { s -= l[i * n + p] * l[j * n + p] }
                l[i * n + j] = i == j ? max(s, 1e-12).squareRoot() : s / l[j * n + j]
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = b[i]
            for p in 0..<i { s -= l[i * n + p] * y[p] }
            y[i] = s / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for p in (i + 1)..<n { s -= l[p * n + i] * x[p] }
            x[i] = s / l[i * n + i]
        }
        return x
    }

    // MARK: Measuring

    func centroid(_ ring: [Int], _ v: [Vec3]) -> Vec3 {
        var s = Vec3(0, 0, 0)
        for i in ring { s = s + v[i] }
        return s * (1 / Float(max(1, ring.count)))
    }

    /// Where the triangles of these parts cross the level y, as (x, z) points; with
    /// `touching`, also the triangles with only one corner in them (the seam to the next
    /// part).
    func slice(_ v: [Vec3], at y: Float, parts keep: Set<Part>, touching: Bool = false) -> [(Float, Float)] {
        var out: [(Float, Float)] = []
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            let ids = (Int(triangles[t]), Int(triangles[t + 1]), Int(triangles[t + 2]))
            let inside = [keep.contains(parts[ids.0]), keep.contains(parts[ids.1]), keep.contains(parts[ids.2])]
            guard touching ? inside.contains(true) : !inside.contains(false) else { continue }
            for (i, j) in [(ids.0, ids.1), (ids.1, ids.2), (ids.2, ids.0)] {
                let a = v[i], b = v[j]
                guard (a.y - y) * (b.y - y) < 0 else { continue }
                let f = (y - a.y) / (b.y - a.y)
                out.append((a.x + (b.x - a.x) * f, a.z + (b.z - a.z) * f))
            }
        }
        return out
    }

    /// Length of a tape round the outside of the points: their convex hull's perimeter.
    static func hullPerimeter(_ points: [(Float, Float)]) -> Float {
        let hull = convexHull(points)
        guard hull.count > 2 else { return 0 }
        var sum: Float = 0
        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            sum += ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1)).squareRoot()
        }
        return sum
    }

    /// Andrew's monotone chain, counter-clockwise.
    static func convexHull(_ points: [(Float, Float)]) -> [(Float, Float)] {
        let p = points.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        guard p.count > 2 else { return p }
        func cross(_ o: (Float, Float), _ a: (Float, Float), _ b: (Float, Float)) -> Float {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        var lower: [(Float, Float)] = [], upper: [(Float, Float)] = []
        for q in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    static let girthParts: Set<Part> = [.torso, .leftLeg, .rightLeg]
    /// How far each shoulder-top point sits out over the bone, m.
    static let shoulderSkin: Float = 0.012

    /// Height, chest, waist, hip, thigh, shoulder, arm and inseam in cm, as
    /// `coefficients(for:)` takes them.
    func measure(_ v: [Vec3]) -> [Double] {
        let floor = v.map(\.y).min() ?? 0
        let height = v[points.top].y - floor
        func girth(_ y: Float, _ keep: Set<Part> = Self.girthParts) -> Float { Self.hullPerimeter(slice(v, at: y, parts: keep)) }
        let thighY = v[points.crotch].y - 0.018 * height
        let a0 = v[points.acromion[0]], a1 = v[points.acromion[1]]
        // Both sides averaged: one side alone would pull the shape lopsided.
        var arm: Float = 0
        for (s, a) in [(0, a0), (1, a1)] {
            let elbow = centroid(rings.elbow[s], v), wrist = centroid(rings.wrist[s], v)
            arm += ((a - elbow).length + (elbow - wrist).length) / 2
        }
        let thigh = (girth(thighY, [.leftLeg]) + girth(thighY, [.rightLeg])) / 2
        let raw: [Float] = [
            height, girth(v[points.nipple].y), girth(v[points.navel].y), girth(v[points.buttock].y),
            thigh, abs(a0.x - a1.x) - 2 * Self.shoulderSkin, arm, v[points.crotch].y - floor,
        ]
        return raw.enumerated().map { Double($1) * 100 * calibration[$0] }
    }
}

extension SomaModel {
    /// How far the breasts stand out, cm: the chest girth at the nipples minus the girth
    /// `drop` × stature below them, under the breasts (a bra's "cup" difference).
    func bust(_ v: [Vec3], drop: Float = 0.05) -> Double {
        let floor = v.map(\.y).min() ?? 0
        let height = v[points.top].y - floor
        let y = v[points.nipple].y
        let at = Self.hullPerimeter(slice(v, at: y, parts: [.torso]))
        let under = Self.hullPerimeter(slice(v, at: y - drop * height, parts: [.torso]))
        return Double(at - under) * 100
    }
}

extension Avatar.Measurements {
    /// In the order the SOMA model takes them.
    var somaTarget: [Double] { [height, chest, waist, hip, thigh, shoulderWidth, armLength, inseam] }
}

/// Notices for the third-party material bundled with the avatar engine.
public enum AvatarNotices {
    /// NVIDIA SOMA-X's licence (Apache-2.0), shipped with its body shape model.
    public static var somaLicense: String? {
        Bundle.module.url(forResource: "SOMA-X-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
