import Foundation

/// A garment as a triangle mesh settled on the body with extended position-based
/// dynamics (XPBD; Macklin, Müller & Chentanez 2016). The rest shape is the garment as
/// cut. Every mesh edge keeps its cut length as a distance constraint with the fabric's
/// stretch compliance; the vertices across each pair of triangles resist folding into
/// each other (bending, push only: cloth buckles rather than compressing), with a
/// compliance from the drape coefficient. Each vertex carries its share of the fabric's
/// weight. Gravity pulls it down; contacts with the body are resolved along the distance
/// field's gradient with friction (fabric pressed on the body slides only as much as its
/// grip lets it); fabric too close to itself that isn't neighbouring in the mesh is
/// pushed apart, so layers don't pass through each other; and where it hangs from
/// (shoulders, waistband) stays put. What's left stretched past its cut length is the
/// strain; where it presses on the body is the contact.
struct TriangleCloth {
    var positions: [Vec3]
    let rest: [Vec3]
    let indices: [UInt32]
    /// Per vertex after draping: stretch past the cut, as a fraction.
    private(set) var stretch: [Float] = []
    /// Per vertex after draping: resting on the body.
    private(set) var contact: [Bool] = []
    /// Per vertex after draping: distance from the skin, metres (0 where touching).
    private(set) var gap: [Float] = []

    private struct Link { let a: Int, b: Int, length: Float }
    private let edges: [Link]
    private let bends: [Link]
    /// Vertex area (a third of each triangle around it), m².
    private let area: [Float]
    /// Vertices one or two edges away, which may sit close without colliding.
    private let nearby: [Set<Int>]
    private let meanEdge: Float

    init(_ mesh: Mesh) {
        positions = mesh.positions
        rest = mesh.positions
        indices = mesh.indices
        var edgeTriangles: [Int: [Int]] = [:]
        var area = [Float](repeating: 0, count: mesh.positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            for e in 0..<3 {
                let a = Int(indices[t + e]), b = Int(indices[t + (e + 1) % 3])
                edgeTriangles[min(a, b) << 32 | max(a, b), default: []].append(t)
            }
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let third = (mesh.positions[b] - mesh.positions[a]).cross(mesh.positions[c] - mesh.positions[a]).length / 6
            area[a] += third; area[b] += third; area[c] += third
        }
        var edges: [Link] = [], bends: [Link] = []
        var ring = [Set<Int>](repeating: [], count: mesh.positions.count)
        let rest = mesh.positions, indices = mesh.indices
        for (key, triangles) in edgeTriangles {
            let a = key >> 32, b = key & 0xFFFF_FFFF
            edges.append(Link(a: a, b: b, length: (rest[a] - rest[b]).length))
            ring[a].insert(b); ring[b].insert(a)
            guard triangles.count == 2 else { continue }
            let opposite: [Int] = triangles.map { (t: Int) -> Int in
                let corners: [Int] = [Int(indices[t]), Int(indices[t + 1]), Int(indices[t + 2])]
                return corners.first { $0 != a && $0 != b } ?? a
            }
            bends.append(Link(a: opposite[0], b: opposite[1], length: (rest[opposite[0]] - rest[opposite[1]]).length))
        }
        self.edges = edges
        self.bends = bends
        self.area = area
        nearby = ring.indices.map { i in ring[i].reduce(into: ring[i]) { $0.formUnion(ring[$1]) } }
        meanEdge = edges.isEmpty ? 0.01 : edges.reduce(0) { $0 + $1.length } / Float(edges.count)
    }

    /// Settles the cloth on the body. `pinned` vertices don't fall or get pulled, but are
    /// still pushed out of the body.
    mutating func drape(body: (Vec3) -> Float, fabric: Fabric, pinned: [Bool], steps: Int = 18, iterations: Int = 4) {
        let thickness = fabric.thickness
        let dt: Float = 1.0 / 60
        let gravity = Vec3(0, -9.81 * dt * dt, 0)
        // Inverse masses: each vertex carries the fabric over its area.
        let kgPerM2 = fabric.density / 1000
        let inverseMass = positions.indices.map { i -> Float in
            pinned[i] ? 0 : 1 / max(1e-7, kgPerM2 * max(area[i], 1e-6))
        }
        let free = inverseMass.filter { $0 > 0 }
        let typicalW = free.isEmpty ? 1 : free.reduce(0, +) / Float(free.count)
        // Compliances (inverse stiffness, m/N). Stretch: a fabric that gives more under
        // the same pull is softer; under a garment's own weight both are nearly rigid, so
        // the stretch that remains comes from the body pushing out the cut. Bending:
        // chosen so a step's correction is the share 0.1 + 0.5·drape of a rigid one at
        // this mesh's typical mass, so stiff fabrics keep their shape and fluid ones fold.
        let stretchCompliance = fabric.stretchLimit * 0.02
        let bendShare: Float = 0.1 + 0.5 * fabric.drape
        let bendCompliance = 2 * typicalW * (1 - bendShare) / bendShare * dt * dt
        var velocity = [Vec3](repeating: Vec3(0, 0, 0), count: positions.count)
        var touching = [Bool](repeating: false, count: positions.count)
        var normal = [Vec3](repeating: Vec3(0, 0, 0), count: positions.count)
        var stretchLambda = [Float](repeating: 0, count: edges.count)
        var bendLambda = [Float](repeating: 0, count: bends.count)

        func solve(_ links: [Link], compliance: Float, lambda: inout [Float], pushOnly: Bool) {
            let alpha = compliance / (dt * dt)
            for k in links.indices {
                let l = links[k]
                let d = positions[l.b] - positions[l.a]
                let len = d.length
                guard len > 1e-6, !(pushOnly && len > l.length) else { continue }
                let wa = inverseMass[l.a], wb = inverseMass[l.b]
                guard wa + wb > 0 else { continue }
                let c = len - l.length
                let dLambda = (-c - alpha * lambda[k]) / (wa + wb + alpha)
                lambda[k] += dLambda
                let n = d * (1 / len)
                positions[l.a] = positions[l.a] - n * (dLambda * wa)
                positions[l.b] = positions[l.b] + n * (dLambda * wb)
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
                if positions[i].y < thickness {
                    positions[i].y = thickness
                    touching[i] = true
                    normal[i] = Vec3(0, 1, 0)
                }
                let d = body(positions[i]) - thickness
                guard d < 0 else { continue }
                let g = gradient(body, at: positions[i])
                positions[i] = positions[i] - g * d
                touching[i] = true
                normal[i] = g
            }
        }
        // Fabric against itself: a spatial hash with cells the size of the minimum
        // distance; pairs closer than it that aren't mesh neighbours are pushed apart.
        let selfDistance = 0.5 * meanEdge
        func separate() {
            func key(_ p: Vec3) -> SIMD3<Int32> {
                SIMD3(Int32((p.x / selfDistance).rounded(.down)), Int32((p.y / selfDistance).rounded(.down)),
                      Int32((p.z / selfDistance).rounded(.down)))
            }
            var grid: [SIMD3<Int32>: [Int]] = [:]
            for i in positions.indices { grid[key(positions[i]), default: []].append(i) }
            for i in positions.indices {
                let k = key(positions[i])
                for dx: Int32 in -1...1 {
                    for dy: Int32 in -1...1 {
                        for dz: Int32 in -1...1 {
                            guard let bucket = grid[k &+ SIMD3(dx, dy, dz)] else { continue }
                            for j in bucket where j > i && !nearby[i].contains(j) {
                                let d = positions[j] - positions[i]
                                let len = d.length
                                guard len < selfDistance, len > 1e-7 else { continue }
                                let wa = inverseMass[i], wb = inverseMass[j]
                                guard wa + wb > 0 else { continue }
                                let push = d * ((selfDistance - len) / len / (wa + wb))
                                positions[i] = positions[i] - push * wa
                                positions[j] = positions[j] + push * wb
                            }
                        }
                    }
                }
            }
        }
        func project() {
            solve(edges, compliance: stretchCompliance, lambda: &stretchLambda, pushOnly: false)
            solve(bends, compliance: bendCompliance, lambda: &bendLambda, pushOnly: true)
            collide()
        }
        func resetLambdas() {
            for k in stretchLambda.indices { stretchLambda[k] = 0 }
            for k in bendLambda.indices { bendLambda[k] = 0 }
        }

        collide()
        for _ in 0..<steps {
            let start = positions
            touching = [Bool](repeating: false, count: positions.count)
            resetLambdas()
            for i in positions.indices where !pinned[i] {
                positions[i] = positions[i] + velocity[i] * dt + gravity
            }
            for _ in 0..<iterations { project() }
            separate()
            collide()
            for i in positions.indices {
                var v = (positions[i] - start[i]) * (1 / dt)
                if touching[i] {
                    // Friction: sliding along the body is held back by the fabric's grip;
                    // motion into the body is gone.
                    let n = normal[i]
                    let normalSpeed = v.dot(n)
                    let along = v - n * normalSpeed
                    v = along * max(0, 1 - 2 * fabric.friction) + n * max(0, normalSpeed)
                }
                velocity[i] = v * 0.6
            }
        }
        // At rest: let the constraints settle what the last steps' weight left unresolved.
        touching = [Bool](repeating: false, count: positions.count)
        resetLambdas()
        for _ in 0..<(iterations * 8) { project() }
        contact = touching
        gap = positions.indices.map { touching[$0] ? 0 : max(0, body(positions[$0]) - thickness) }

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
