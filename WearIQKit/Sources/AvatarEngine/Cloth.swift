import Foundation

/// How a fabric behaves on the body, from its composition.
///
/// Stretch: elastane is what lets a fabric extend and recover; knits give more than
/// wovens. A rigid woven takes about 3–4% before it pulls, a plain knit around 12%, and
/// each per cent of elastane adds roughly 4% (a 98/2 stretch chino ≈ 11%, a 95/5 jersey
/// ≈ 32%).
///
/// Drape: the Cusick drape coefficient, the share of a draped disc's shadow against its
/// flat area. Fluid fabrics (viscose, silk) sit around 0.2–0.4 and fall into many deep
/// folds; cotton around 0.5–0.6; linen and denim 0.7 and above hang stiffly in a few
/// wide folds. The number of folds a drape forms falls as the coefficient rises.
public struct Fabric: Equatable, Sendable {
    /// Extension taken comfortably before the fabric pulls, as a fraction.
    public var stretchLimit: Float
    /// Cusick drape coefficient, 0 (fluid) to 1 (stiff).
    public var drape: Float

    public init(stretchLimit: Float, drape: Float) {
        self.stretchLimit = max(0.02, stretchLimit)
        self.drape = min(0.95, max(0.15, drape))
    }

    public static let woven = Fabric(stretchLimit: 0.035, drape: 0.6)
    public static let knit = Fabric(stretchLimit: 0.12, drape: 0.45)

    /// From fibre percentages keyed by fibre name (elastane, cotton, polyester, viscose,
    /// wool, linen, polyamide, acrylic); unknown or missing fibres count as cotton.
    public init(fibres: [String: Double], knit: Bool) {
        let drapeOf: [String: Float] = [
            "cotton": 0.55, "viscose": 0.28, "wool": 0.5, "linen": 0.72, "polyester": 0.45,
            "polyamide": 0.4, "acrylic": 0.55, "elastane": 0.5,
        ]
        let total = fibres.values.reduce(0, +)
        var drape: Float = 0.55
        if total > 0 {
            drape = 0
            for (fibre, percent) in fibres { drape += (drapeOf[fibre] ?? 0.55) * Float(percent / total) }
        }
        let elastane = Float(fibres["elastane"] ?? 0)
        self.init(stretchLimit: (knit ? 0.12 : 0.035) + 0.04 * min(elastane, 10),
                  drape: drape - (knit ? 0.08 : 0))
    }

    /// Folds a loose drape falls into around the body.
    var folds: Int { Int((4 + (1 - drape) * 7).rounded()) }
}

/// Pushes a point out of the body; `thickness` is how far the fabric's midline sits off
/// the skin.
struct BodyCollider {
    /// Torso sections, bottom to top.
    var torso: [Ring] = []
    /// Limbs as tapered capsules: radii spread evenly from `a` to `b`.
    var limbs: [(a: Vec3, b: Vec3, radii: [Float])] = []
    var floorY: Float = 0.003

    /// The torso section at a height, interpolated.
    func torsoRing(at y: Float) -> Ring? {
        guard let first = torso.first, let last = torso.last else { return nil }
        if y <= first.center.y { return first }
        if y >= last.center.y { return last }
        var lo = 0, hi = torso.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if torso[mid].center.y <= y { lo = mid } else { hi = mid }
        }
        let a = torso[lo], b = torso[hi]
        let span = b.center.y - a.center.y
        return a.lerp(b, span > 0 ? (y - a.center.y) / span : 0)
    }

    func resolve(_ p: Vec3, thickness: Float) -> Vec3 {
        var p = p
        if let ring = torsoRing(at: p.y), p.y >= torso[0].center.y - 0.01 {
            let dx = p.x - ring.center.x, dz = p.z - ring.center.z
            let a = ring.halfWidth + thickness, b = ring.halfDepth + thickness
            let across: Float = pow(abs(dx / a), ring.power)
            let deep: Float = pow(abs(dz / b), ring.power)
            let norm: Float = pow(across + deep, 1 / ring.power)
            if norm < 1, norm > 1e-4 {
                p.x = ring.center.x + dx / norm
                p.z = ring.center.z + dz / norm
            }
        }
        for limb in limbs {
            let axis = limb.b - limb.a
            let len = axis.length
            guard len > 0 else { continue }
            let dir = axis * (1 / len)
            let t = min(1, max(0, (p - limb.a).dot(dir) / len))
            let f = t * Float(limb.radii.count - 1)
            let k = max(0, min(limb.radii.count - 2, Int(f)))
            let r = (limb.radii.count > 1 ? limb.radii[k] + (limb.radii[k + 1] - limb.radii[k]) * (f - Float(k)) : limb.radii[0]) + thickness
            let q = limb.a + axis * t
            let d = p - q
            let dist = d.length
            if dist < r, dist > 1e-5 { p = q + d * (r / dist) }
        }
        if p.y < floorY { p.y = floorY }
        return p
    }
}

/// A garment panel as rings of particles wrapped around a body part: the rest shape is
/// the garment as cut (its own circumference at each ring), the drape is where position-
/// based dynamics (Müller et al. 2007) settles it on the body under gravity. Rings keep
/// their cut lengths as distance constraints, a weaker skip-one constraint gives the
/// fabric its bending stiffness, collisions keep it out of the body and the top ring is
/// held where the garment hangs from (neckline, sleeve seam or waistband). What's left
/// stretched past its cut length is the strain the fit map shows. Long-range attachments
/// (Kim, Chentanez & Müller 2012) tether every particle to the held ring so the fabric
/// can't creep longer under its own weight, as a real one doesn't.
struct ClothPiece {
    let n: Int
    var positions: [Vec3]
    /// Ring centres along the piece, for fold placement.
    var centers: [Vec3]
    private let rest: [Vec3]
    /// Strain after draping, before cosmetic folds are added.
    private(set) var strainMap: [Float] = []
    var ringCount: Int { centers.count }

    init(rings: [[Vec3]], centers: [Vec3]) {
        n = rings.first?.count ?? 0
        positions = rings.flatMap { $0 }
        rest = positions
        self.centers = centers
    }

    private struct Link { let a: Int, b: Int, length: Float, stiffness: Float }

    private func links(fabric: Fabric) -> (stretch: [Link], bend: [Link]) {
        var stretch: [Link] = [], bend: [Link] = []
        let bendK = 0.08 + 0.5 * fabric.drape
        func link(_ a: Int, _ b: Int, _ k: Float) -> Link { Link(a: a, b: b, length: (rest[a] - rest[b]).length, stiffness: k) }
        for r in 0..<ringCount {
            for i in 0..<n {
                let a = r * n + i
                stretch.append(link(a, r * n + (i + 1) % n, 1))
                if r + 1 < ringCount { stretch.append(link(a, a + n, 1)) }
                if r + 2 < ringCount { bend.append(link(a, a + 2 * n, bendK)) }
                bend.append(link(a, r * n + (i + 2) % n, bendK * 0.5))
            }
        }
        return (stretch, bend)
    }

    /// Settles the piece on the body. Pinned rings keep their rest positions.
    mutating func drape(on body: BodyCollider, fabric: Fabric, pinned: Set<Int>, steps: Int = 30, iterations: Int = 6) {
        guard n > 0 else { return }
        let (stretch, bend) = links(fabric: fabric)
        let thickness: Float = 0.0025
        let dt: Float = 1.0 / 60
        let gravity = Vec3(0, -9.81 * dt * dt, 0)
        var velocity = [Vec3](repeating: Vec3(0, 0, 0), count: positions.count)
        var fixed = [Bool](repeating: false, count: positions.count)
        for i in positions.indices { fixed[i] = pinned.contains(i / n) }
        // Each particle's tether: the nearest held ring's particle in the same column, at
        // the length down the column, not the straight line: the fabric may fall straight
        // but never get longer.
        var tethers = [(anchor: Int, length: Float)?](repeating: nil, count: positions.count)
        for a in positions.indices where !fixed[a] {
            let r = a / n, column = a % n
            guard let ring = pinned.min(by: { abs($0 - r) < abs($1 - r) }) else { continue }
            var path: Float = 0
            for k in min(r, ring)..<max(r, ring) {
                let step: Vec3 = rest[(k + 1) * n + column] - rest[k * n + column]
                path += step.length
            }
            tethers[a] = (ring * n + column, path)
        }
        var touching = [Bool](repeating: false, count: positions.count)
        func project() {
            for (set, pushOnly) in [(stretch, false), (bend, true)] {
                for l in set {
                    let d = positions[l.b] - positions[l.a]
                    let len = d.length
                    guard len > 1e-6 else { continue }
                    // Cloth resists stretching far more than compression, which it
                    // takes by buckling: bending links only push apart, never pull in.
                    if pushOnly, len > l.length { continue }
                    let wa: Float = fixed[l.a] ? 0 : 1, wb: Float = fixed[l.b] ? 0 : 1
                    guard wa + wb > 0 else { continue }
                    let corr = d * ((len - l.length) / len * l.stiffness / (wa + wb))
                    positions[l.a] = positions[l.a] + corr * wa
                    positions[l.b] = positions[l.b] - corr * wb
                }
            }
            for i in positions.indices where !fixed[i] {
                if let tether = tethers[i] {
                    let d = positions[i] - positions[tether.anchor]
                    let len = d.length
                    if len > tether.length { positions[i] = positions[tether.anchor] + d * (tether.length / len) }
                }
                let free = positions[i]
                positions[i] = body.resolve(free, thickness: thickness)
                if positions[i] != free { touching[i] = true }
            }
        }
        for _ in 0..<steps {
            let start = positions
            touching = [Bool](repeating: false, count: positions.count)
            for i in positions.indices where !fixed[i] {
                positions[i] = positions[i] + velocity[i] * dt + gravity
            }
            for _ in 0..<iterations { project() }
            for i in positions.indices {
                // Friction: fabric pressed on the body stops sliding.
                velocity[i] = touching[i] ? Vec3(0, 0, 0) : (positions[i] - start[i]) * (0.6 / dt)
            }
        }
        // At rest: let the constraints settle what the last steps' weight left unresolved.
        for _ in 0..<(iterations * 15) { project() }
        strainMap = strain(fabric: fabric)
        for r in 0..<ringCount {
            let ring = positions[(r * n)..<((r + 1) * n)]
            var sum = Vec3(0, 0, 0)
            for p in ring { sum = sum + p }
            centers[r] = sum * (1 / Float(n))
        }
    }

    /// Per-vertex strain round the body relative to the fabric's stretch limit: 0
    /// relaxed, 1 at the limit, above 1 pulling. Mostly the whole ring's stretch (a
    /// garment too small all round), partly the local one (a point it presses on), less
    /// the 1% a fabric settles into on contact; lengthwise pull is left out.
    private func strain(fabric: Fabric) -> [Float] {
        var out = [Float](repeating: 0, count: positions.count)
        for r in 0..<ringCount {
            var local = [Float](repeating: 0, count: n)
            var length: Float = 0, restLength: Float = 0
            for i in 0..<n {
                let a = r * n + i, b = r * n + (i + 1) % n
                let l = (positions[a] - positions[b]).length, l0 = (rest[a] - rest[b]).length
                length += l; restLength += l0
                local[i] = l0 > 1e-6 ? l / l0 - 1 : 0
            }
            let ring = restLength > 0 ? length / restLength - 1 : 0
            for i in 0..<n {
                let here = max(local[i], local[(i + n - 1) % n])
                out[r * n + i] = max(0, 0.7 * ring + 0.3 * here - 0.01) / fabric.stretchLimit
            }
        }
        return out
    }

    /// Loose fabric hanging in vertical folds: ripples outward where the cut is at least
    /// 5 cm wider than the body, deepening towards the free edge. Fluid fabrics make more,
    /// deeper folds than stiff ones.
    mutating func addDrapeFolds(slack: (Int) -> Float, fabric: Fabric) {
        guard ringCount > 1 else { return }
        for r in 0..<ringCount {
            let extra = slack(r) - 0.05
            guard extra > 0 else { continue }
            let towardsEdge = Float(r) / Float(ringCount - 1)
            let depth = min(0.014, extra * 0.12) * (1.25 - fabric.drape) * towardsEdge
            for i in 0..<n {
                let a = r * n + i
                let radial = Vec3(positions[a].x - centers[r].x, 0, positions[a].z - centers[r].z).normalized
                let t = Float(i) / Float(n) * 2 * .pi
                positions[a] = positions[a] + radial * (depth * 0.5 * (1 + cos(Float(fabric.folds) * t)))
            }
        }
    }

    func mesh(fabric: Fabric) -> Mesh {
        var mesh = Mesh()
        mesh.positions = positions
        mesh.indices = Mesh.gridIndices(rings: ringCount, n: n)
        mesh.strain = strainMap.count == positions.count ? strainMap : strain(fabric: fabric)
        mesh.computeNormals()
        return mesh
    }
}
