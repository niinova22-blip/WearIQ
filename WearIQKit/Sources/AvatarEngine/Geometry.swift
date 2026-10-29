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
    func dot(_ b: Vec3) -> Float { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
}

/// Triangles with smooth per-vertex normals, ready for SceneKit or RealityKit.
public struct Mesh: Sendable {
    public var positions: [Vec3] = []
    public var normals: [Vec3] = []
    public var indices: [UInt32] = []
    /// Per-vertex fabric strain for garments: 0 relaxed, 1 at the fabric's stretch limit
    /// (and above when it would have to stretch further). Empty for the body.
    public var strain: [Float] = []

    public init() {}

    mutating func append(_ other: Mesh) {
        let offset = UInt32(positions.count)
        positions += other.positions
        normals += other.normals
        indices += other.indices.map { $0 + offset }
        if !other.strain.isEmpty || !strain.isEmpty {
            strain += [Float](repeating: 0, count: max(0, positions.count - other.positions.count - strain.count))
            strain += other.strain.isEmpty ? [Float](repeating: 0, count: other.positions.count) : other.strain
        }
    }

    public var minY: Float { positions.map(\.y).min() ?? 0 }
    public var maxY: Float { positions.map(\.y).max() ?? 0 }
    public var maxStrain: Float { strain.max() ?? 0 }

    mutating func computeNormals() {
        var sums = [Vec3](repeating: Vec3(0, 0, 0), count: positions.count)
        for t in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let n = (positions[b] - positions[a]).cross(positions[c] - positions[a])
            sums[a] = sums[a] + n; sums[b] = sums[b] + n; sums[c] = sums[c] + n
        }
        normals = sums.map(\.normalized)
    }

    /// Triangles for a grid of `rings` × `n` vertices wrapped around.
    static func gridIndices(rings: Int, n: Int, start: Int = 0) -> [UInt32] {
        var idx: [UInt32] = []
        for r in 0..<(rings - 1) {
            for i in 0..<n {
                let a = UInt32(start + r * n + i), b = UInt32(start + r * n + (i + 1) % n)
                let c = UInt32(start + (r + 1) * n + i), d = UInt32(start + (r + 1) * n + (i + 1) % n)
                idx += [a, c, b, b, c, d]
            }
        }
        return idx
    }
}

/// A horizontal cross-section: centre, half-width across (x), half-depth (z) and a
/// superellipse exponent (2 = ellipse; torsos are a little boxier, about 2.4).
struct Ring {
    var center: Vec3
    var halfWidth: Float
    var halfDepth: Float
    var power: Float = 2

    /// Point on the section at angle t (0 = towards +x).
    func point(_ t: Float, grow: Float = 0) -> Vec3 {
        let c = cos(t), s = sin(t), e = 2 / power
        let x = (halfWidth + grow) * copysign(pow(abs(c), e), c)
        let z = (halfDepth + grow) * copysign(pow(abs(s), e), s)
        return Vec3(center.x + x, center.y, center.z + z)
    }

    func lerp(_ b: Ring, _ f: Float) -> Ring {
        Ring(center: center + (b.center - center) * f, halfWidth: halfWidth + (b.halfWidth - halfWidth) * f,
             halfDepth: halfDepth + (b.halfDepth - halfDepth) * f, power: power + (b.power - power) * f)
    }

    /// The same shape scaled about its centre to this perimeter.
    func scaled(toPerimeter target: Float) -> Ring {
        let s = target / perimeter
        return Ring(center: center, halfWidth: halfWidth * s, halfDepth: halfDepth * s, power: power)
    }

    /// Perimeter, by summing the polygon.
    var perimeter: Float {
        let n = 64
        var sum: Float = 0
        var prev = point(0)
        for i in 1...n {
            let p = point(Float(i) / Float(n) * 2 * .pi)
            sum += (p - prev).length
            prev = p
        }
        return sum
    }
}

enum Shapes {
    static let segments = 48

    /// Smooths a list of key sections with Catmull–Rom interpolation (`steps` per gap),
    /// so the body flows between the measured levels instead of showing kinks.
    static func smooth(_ keys: [Ring], steps: Int = 6) -> [Ring] {
        guard keys.count > 2 else { return keys }
        func cr(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t * t * t)
        }
        var out: [Ring] = []
        for i in 0..<(keys.count - 1) {
            let p0 = keys[max(0, i - 1)], p1 = keys[i], p2 = keys[i + 1], p3 = keys[min(keys.count - 1, i + 2)]
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                out.append(Ring(
                    center: Vec3(cr(p0.center.x, p1.center.x, p2.center.x, p3.center.x, t),
                                 cr(p0.center.y, p1.center.y, p2.center.y, p3.center.y, t),
                                 cr(p0.center.z, p1.center.z, p2.center.z, p3.center.z, t)),
                    halfWidth: max(0.001, cr(p0.halfWidth, p1.halfWidth, p2.halfWidth, p3.halfWidth, t)),
                    halfDepth: max(0.001, cr(p0.halfDepth, p1.halfDepth, p2.halfDepth, p3.halfDepth, t)),
                    power: p1.power + (p2.power - p1.power) * t))
            }
        }
        out.append(keys[keys.count - 1])
        return out
    }

    /// A tube through horizontal sections (bottom to top), optionally capped.
    static func loft(_ rings: [Ring], capped: Bool = true) -> Mesh {
        var mesh = Mesh()
        let n = segments
        for ring in rings {
            for i in 0..<n { mesh.positions.append(ring.point(Float(i) / Float(n) * 2 * .pi)) }
        }
        mesh.indices = Mesh.gridIndices(rings: rings.count, n: n)
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

    /// Frame of a segment: unit vectors across it.
    static func frame(_ a: Vec3, _ b: Vec3) -> (u: Vec3, v: Vec3) {
        let axis = (b - a).normalized
        let helper = abs(axis.y) < 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0)
        let u = axis.cross(helper).normalized
        return (u, axis.cross(u).normalized)
    }

    /// A tapered tube along a segment; `radii` are spread evenly along it. `flatten`
    /// squashes it across (hands, feet).
    static func tube(from a: Vec3, to b: Vec3, radii: [Float], capped: Bool = true, flatten: Float = 1) -> Mesh {
        let (u, v0) = frame(a, b)
        let v = v0 * flatten
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
        mesh.indices = Mesh.gridIndices(rings: radii.count, n: n)
        if capped {
            cap(&mesh, center: a, ringStart: 0, facingUp: false)
            cap(&mesh, center: b, ringStart: (radii.count - 1) * n, facingUp: true)
        }
        mesh.computeNormals()
        return mesh
    }

    /// Radii smoothed between key values, `steps` per gap.
    static func smoothRadii(_ keys: [Float], steps: Int = 4) -> [Float] {
        guard keys.count > 1 else { return keys }
        var out: [Float] = []
        for i in 0..<(keys.count - 1) {
            for s in 0..<steps {
                let t = Float(s) / Float(steps)
                // Smoothstep easing between keys.
                let e = t * t * (3 - 2 * t)
                out.append(keys[i] + (keys[i + 1] - keys[i]) * e)
            }
        }
        out.append(keys[keys.count - 1])
        return out
    }

    static func ellipsoid(center: Vec3, radii: Vec3, stacks: Int = 20) -> Mesh {
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
