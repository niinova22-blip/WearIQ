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
/// A garment as a triangle mesh settled on the body with position-based dynamics
/// (Müller et al. 2007). The rest shape is the garment as cut; every mesh edge keeps its
/// cut length as a distance constraint, and the vertices across each pair of triangles
/// resist folding flat into each other (bending, push only: cloth buckles rather than
/// compressing). Gravity pulls it down, contacts with the body are resolved along the
/// distance field's gradient with friction (fabric pressed on the body doesn't slide),
/// and where it hangs from (shoulders, waistband) stays put. What's left stretched past
/// its cut length is the strain; where it presses on the body is the contact.
struct TriangleCloth {
    var positions: [Vec3]
    let rest: [Vec3]
    let indices: [UInt32]
    /// Per vertex after draping: stretch past the cut, as a fraction.
    private(set) var stretch: [Float] = []
    /// Per vertex after draping: resting on the body.
    private(set) var contact: [Bool] = []

    private struct Link { let a: Int, b: Int, length: Float }
    private let edges: [Link]
    private let bends: [Link]

    init(_ mesh: Mesh) {
        positions = mesh.positions
        rest = mesh.positions
        indices = mesh.indices
        var edgeTriangles: [Int: [Int]] = [:]
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            for e in 0..<3 {
                let a = Int(indices[t + e]), b = Int(indices[t + (e + 1) % 3])
                edgeTriangles[min(a, b) << 32 | max(a, b), default: []].append(t)
            }
        }
        var edges: [Link] = [], bends: [Link] = []
        let rest = mesh.positions, indices = mesh.indices
        for (key, triangles) in edgeTriangles {
            let a = key >> 32, b = key & 0xFFFF_FFFF
            edges.append(Link(a: a, b: b, length: (rest[a] - rest[b]).length))
            guard triangles.count == 2 else { continue }
            let opposite = triangles.map { t in (0..<3).map { Int(indices[t + $0]) }.first { $0 != a && $0 != b } ?? a }
            bends.append(Link(a: opposite[0], b: opposite[1], length: (rest[opposite[0]] - rest[opposite[1]]).length))
        }
        self.edges = edges
        self.bends = bends
    }

    /// Settles the cloth on the body. `pinned` vertices don't fall or get pulled, but are
    /// still pushed out of the body.
    mutating func drape(body: (Vec3) -> Float, fabric: Fabric, pinned: [Bool], steps: Int = 18, iterations: Int = 4) {
        let thickness: Float = 0.003
        let dt: Float = 1.0 / 60
        let gravity = Vec3(0, -9.81 * dt * dt, 0)
        let bendStiffness: Float = 0.1 + 0.5 * fabric.drape
        var velocity = [Vec3](repeating: Vec3(0, 0, 0), count: positions.count)
        var touching = [Bool](repeating: false, count: positions.count)

        func solve(_ links: [Link], stiffness: Float, pushOnly: Bool) {
            for l in links {
                let d = positions[l.b] - positions[l.a]
                let len = d.length
                guard len > 1e-6, !(pushOnly && len > l.length) else { continue }
                let wa: Float = pinned[l.a] ? 0 : 1, wb: Float = pinned[l.b] ? 0 : 1
                guard wa + wb > 0 else { continue }
                let corr = d * ((len - l.length) / len * stiffness / (wa + wb))
                positions[l.a] = positions[l.a] + corr * wa
                positions[l.b] = positions[l.b] - corr * wb
            }
        }
        // Long-range attachments (Kim, Chentanez & Müller 2012): every free vertex stays
        // within its rest distance of the nearest held vertex, so the fabric can't creep
        // longer under its own weight, as a real one doesn't.
        let held = positions.indices.filter { pinned[$0] }
        var tethers = [(anchor: Int, length: Float)?](repeating: nil, count: positions.count)
        if !held.isEmpty {
            for i in positions.indices where !pinned[i] {
                var best = held[0], bestD = Float.greatestFiniteMagnitude
                for j in held {
                    let d = (rest[i] - rest[j]).length
                    if d < bestD { best = j; bestD = d }
                }
                tethers[i] = (best, bestD)
            }
        }
        func collide() {
            for i in positions.indices {
                if let tether = tethers[i] {
                    let d = positions[i] - positions[tether.anchor]
                    let len = d.length
                    if len > tether.length { positions[i] = positions[tether.anchor] + d * (tether.length / len) }
                }
                if positions[i].y < thickness { positions[i].y = thickness; touching[i] = true }
                let d = body(positions[i]) - thickness
                guard d < 0 else { continue }
                positions[i] = positions[i] - gradient(body, at: positions[i]) * d
                touching[i] = true
            }
        }
        func project() {
            solve(edges, stiffness: 1, pushOnly: false)
            solve(bends, stiffness: bendStiffness, pushOnly: true)
            collide()
        }

        collide()
        for _ in 0..<steps {
            let start = positions
            touching = [Bool](repeating: false, count: positions.count)
            for i in positions.indices where !pinned[i] {
                positions[i] = positions[i] + velocity[i] * dt + gravity
            }
            for _ in 0..<iterations { project() }
            for i in positions.indices {
                // Friction: fabric pressed on the body stops sliding.
                velocity[i] = touching[i] ? Vec3(0, 0, 0) : (positions[i] - start[i]) * (0.6 / dt)
            }
        }
        // At rest: let the constraints settle what the last steps' weight left unresolved.
        touching = [Bool](repeating: false, count: positions.count)
        for _ in 0..<(iterations * 8) { project() }
        contact = touching

        // The most stretched edge at each vertex: a garment pulled round the body
        // stretches across, not along.
        var most = [Float](repeating: 0, count: positions.count)
        for l in edges where l.length > 1e-6 {
            let e = max(0, (positions[l.a] - positions[l.b]).length / l.length - 1)
            most[l.a] = max(most[l.a], e); most[l.b] = max(most[l.b], e)
        }
        stretch = most
    }
}

/// How a garment sits at each point, for the fit map, after CLO 3D's fit maps: 0 loose
/// (not touching), about 0.35 resting on the body, 0.6 tight (half the fabric's stretch
/// limit used), 1 very tight (at the limit), above that it can't stretch that far.
func fitValues(stretch: [Float], contact: [Bool], fabric: Fabric, neighbours: [[Int]]) -> [Float] {
    let raw = stretch.indices.map { i -> Float in
        let used = max(0, stretch[i] - 0.008) / fabric.stretchLimit
        return contact[i] ? max(0.35, 0.35 + used * 0.65) : min(used, 0.3)
    }
    // One smoothing pass, so single vertices don't speckle.
    var out = raw
    for i in raw.indices where !neighbours[i].isEmpty {
        var around: Float = 0
        for j in neighbours[i] { around += raw[j] }
        out[i] = 0.5 * raw[i] + 0.5 * around / Float(neighbours[i].count)
    }
    return out
}
