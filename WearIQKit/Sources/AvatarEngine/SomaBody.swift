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
    func coefficients(for target: [Double]) -> [Double] {
        let k = components, m = Self.measurementCount
        let w = residualSD.map { 1 / pow(max($0, 0.4), 2) }
        // Normal equations (Bᵀ W B + I) c = Bᵀ W (t − m0).
        var a = [Double](repeating: 0, count: k * k)
        for i in 0..<k {
            a[i * k + i] = 1
            for j in 0..<k {
                var s = 0.0
                for r in 0..<m { s += b[r * k + i] * w[r] * b[r * k + j] }
                a[i * k + j] += s
            }
        }
        func solve(_ goal: [Double]) -> [Double] {
            var rhs = [Double](repeating: 0, count: k)
            for i in 0..<k { for r in 0..<m { rhs[i] += b[r * k + i] * w[r] * (goal[r] - m0[r]) } }
            return Self.choleskySolve(a, rhs, k).map { max(-3.5, min(3.5, $0)) }
        }
        var goal = target
        var c = solve(goal)
        for _ in 0..<2 {
            let got = measure(vertices(c))
            for r in 0..<m { goal[r] += target[r] - got[r] }
            c = solve(goal)
        }
        return c
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
