import Foundation

/// A point or direction in metres; y up, x to the avatar's left, z forward.
public struct Vec3: Equatable, Sendable {
    public var x, y, z: Float
    public init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Float) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public var length: Float { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vec3 { let l = length; return l > 0 ? self * (1 / l) : self }
    public func dot(_ b: Vec3) -> Float { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
}

/// Triangles with smooth per-vertex normals, ready for SceneKit or RealityKit.
public struct Mesh: Sendable {
    public var positions: [Vec3] = []
    public var normals: [Vec3] = []
    public var indices: [UInt32] = []
    /// Per-vertex fit for garments, for the fit map: 0 loose, about 0.35 resting on the
    /// body, 1 at the fabric's stretch limit, above it pulling. Empty for the body.
    public var strain: [Float] = []
    /// Per-vertex for garments: how that part sits (see `FitTone`), and how strongly,
    /// 0–1, for blending its colour over the colour of a good fit.
    public var tones: [FitTone] = []
    public var toneWeight: [Float] = []
    /// Per-vertex for garments: how freely the fabric swings when the body turns, 0 where
    /// it hangs from (shoulders, waistband) to 1 for a loose hem of fluid fabric.
    public var sway: [Float] = []

    public init() {}

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
