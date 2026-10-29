import Foundation

/// A point or direction in metres; y up, x to the avatar's left, z forward.
public struct Vec3: Equatable, Sendable {
    public var x, y, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: Vec3, s: Float) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    var length: Float { (x * x + y * y + z * z).squareRoot() }
    var normalized: Vec3 { let l = length; return l > 0 ? self * (1 / l) : self }
    func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
}

/// Triangles with smooth per-vertex normals, ready for SceneKit or RealityKit.
public struct Mesh: Sendable {
    public var positions: [Vec3] = []
    public var normals: [Vec3] = []
    public var indices: [UInt32] = []

    public init() {}

    mutating func append(_ other: Mesh) {
        let offset = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        indices += other.indices.map { $0 + offset }
    }

    /// Lowest point of the mesh, for tests and placing labels.
    public var minY: Float { positions.map(\.y).min() ?? 0 }
    public var maxY: Float { positions.map(\.y).max() ?? 0 }

    mutating func computeNormals() {
        var sums = [Vec3](repeating: Vec3(0, 0, 0), count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = (positions[b] - positions[a]).cross(positions[c] - positions[a])
            sums[a] = sums[a] + n; sums[b] = sums[b] + n; sums[c] = sums[c] + n
        }
        normals = sums.map(\.normalized)
    }
}

/// An elliptical cross-section: centre, half-width across (x) and half-depth (z).
struct Ring {
    var center: Vec3
    var halfWidth: Float
    var halfDepth: Float
}

enum Shapes {
    static let segments = 28

    /// A closed tube through horizontal elliptical rings (bottom to top), capped at both ends.
    static func loft(_ rings: [Ring], capped: Bool = true) -> Mesh {
        var mesh = Mesh()
        let n = segments
        for ring in rings {
            for i in 0..<n {
                let t = Float(i) / Float(n) * 2 * .pi
                mesh.positions.append(Vec3(ring.center.x + ring.halfWidth * cos(t), ring.center.y,
                                           ring.center.z + ring.halfDepth * sin(t)))
            }
        }
        for r in 0..<(rings.count - 1) {
            for i in 0..<n {
                let a = UInt32(r * n + i), b = UInt32(r * n + (i + 1) % n)
                let c = UInt32((r + 1) * n + i), d = UInt32((r + 1) * n + (i + 1) % n)
                mesh.indices += [a, c, b, b, c, d]
            }
        }
        if capped, let first = rings.first, let last = rings.last {
            cap(&mesh, center: first.center, ringStart: 0, facingUp: false)
            cap(&mesh, center: last.center, ringStart: (rings.count - 1) * n, facingUp: true)
        }
        mesh.computeNormals()
        return mesh
    }

    private static func cap(_ mesh: inout Mesh, center: Vec3, ringStart: Int, facingUp: Bool) {
        let c = UInt32(mesh.positions.count)
        mesh.positions.append(center)
        for i in 0..<segments {
            let a = UInt32(ringStart + i), b = UInt32(ringStart + (i + 1) % segments)
            mesh.indices += facingUp ? [c, b, a] : [c, a, b]
        }
    }

    /// A tapered tube along a segment, with round cross-sections; extra rings along the
    /// way can bulge (folds of fabric).
    static func tube(from a: Vec3, to b: Vec3, radii: [Float], capped: Bool = true) -> Mesh {
        let axis = (b - a).normalized
        // Any vector not parallel to the axis gives the ring's frame.
        let helper = abs(axis.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let u = axis.cross(helper).normalized, v = axis.cross(u).normalized
        var mesh = Mesh()
        let n = segments
        for (k, r) in radii.enumerated() {
            let f = radii.count > 1 ? Float(k) / Float(radii.count - 1) : 0
            let c = a + (b - a) * f
            for i in 0..<n {
                let t = Float(i) / Float(n) * 2 * .pi
                mesh.positions.append(c + u * (r * cos(t)) + v * (r * sin(t)))
            }
        }
        for r in 0..<(radii.count - 1) {
            for i in 0..<n {
                let p = UInt32(r * n + i), q = UInt32(r * n + (i + 1) % n)
                let s = UInt32((r + 1) * n + i), t = UInt32((r + 1) * n + (i + 1) % n)
                mesh.indices += [p, s, q, q, s, t]
            }
        }
        if capped {
            cap(&mesh, center: a, ringStart: 0, facingUp: false)
            cap(&mesh, center: b, ringStart: (radii.count - 1) * n, facingUp: true)
        }
        mesh.computeNormals()
        return mesh
    }

    static func ellipsoid(center: Vec3, radii: Vec3, stacks: Int = 14) -> Mesh {
        var mesh = Mesh()
        let n = segments
        for s in 0...stacks {
            let phi = Float(s) / Float(stacks) * .pi
            for i in 0..<n {
                let t = Float(i) / Float(n) * 2 * .pi
                mesh.positions.append(Vec3(center.x + radii.x * sin(phi) * cos(t), center.y + radii.y * cos(phi),
                                           center.z + radii.z * sin(phi) * sin(t)))
            }
        }
        for s in 0..<stacks {
            for i in 0..<n {
                let a = UInt32(s * n + i), b = UInt32(s * n + (i + 1) % n)
                let c = UInt32((s + 1) * n + i), d = UInt32((s + 1) * n + (i + 1) % n)
                mesh.indices += [a, b, c, b, d, c]
            }
        }
        mesh.computeNormals()
        return mesh
    }

    /// Half-width and half-depth of an ellipse with this circumference and depth/width
    /// ratio (Ramanujan's approximation, inverted).
    static func ellipse(girthCm: Double, depthRatio: Double) -> (Float, Float) {
        let r = depthRatio
        let h = ((1 - r) * (1 - r)) / ((1 + r) * (1 + r))
        let factor = Double.pi * (1 + r) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
        let a = girthCm / factor / 100
        return (Float(a), Float(a * r))
    }
}
