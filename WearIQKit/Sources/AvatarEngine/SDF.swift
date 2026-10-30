import Foundation

// Shapes as signed distance fields: negative inside, positive outside, zero on the
// surface. Body parts are blended with a smooth minimum (Quilez), so shoulders, hips and
// joints flow into each other without seams, and the surface is extracted as a mesh
// with surface nets (Gibson 1998).

/// Smooth union of two distances; `k` is roughly how far the blend reaches.
@inline(__always) func smin(_ a: Float, _ b: Float, _ k: Float) -> Float {
    guard k > 0 else { return min(a, b) }
    let h = max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
}

/// A tapered capsule from `a` (radius `ra`) to `b` (radius `rb`).
struct Bone: Sendable {
    var a: Vec3, b: Vec3, ra: Float, rb: Float

    /// Distance, and how far along the bone (0–1) the closest axis point is.
    @inline(__always) func distance(_ p: Vec3) -> (d: Float, t: Float) {
        let ab = b - a, ap = p - a
        let t = min(1, max(0, ap.dot(ab) / max(1e-9, ab.dot(ab))))
        return ((ap - ab * t).length - (ra + (rb - ra) * t), t)
    }
}

/// A chain of bones blended together (a leg, an arm).
struct Limb: Sendable {
    var bones: [Bone]
    var blend: Float = 0.006

    @inline(__always) func distance(_ p: Vec3) -> Float {
        var d = Float.greatestFiniteMagnitude
        for bone in bones { d = smin(d, bone.distance(p).d, blend) }
        return d
    }

    /// Distance along the chain from its start to the point closest to `p`, in metres.
    func reach(_ p: Vec3) -> Float {
        var best = Float.greatestFiniteMagnitude, along: Float = 0, start: Float = 0
        for bone in bones {
            let (d, t) = bone.distance(p)
            let len = (bone.b - bone.a).length
            if d < best { best = d; along = start + t * len }
            start += len
        }
        return along
    }
}

/// An ellipsoid in a local frame (`axis` is its long y axis).
struct Ellipsoid: Sendable {
    var center: Vec3
    var radii: Vec3
    /// Local frame: x, y, z unit vectors.
    var frame: (Vec3, Vec3, Vec3) = (Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1))

    @inline(__always) func distance(_ p: Vec3) -> Float {
        let q = p - center
        let lx: Float = q.dot(frame.0) / radii.x, ly: Float = q.dot(frame.1) / radii.y, lz: Float = q.dot(frame.2) / radii.z
        let k0 = Vec3(lx, ly, lz).length
        let k1 = Vec3(lx / radii.x, ly / radii.y, lz / radii.z).length
        return k1 > 1e-9 ? k0 * (k0 - 1) / k1 : -min(radii.x, radii.y, radii.z)
    }
}

/// A torso lofted through horizontal superellipse sections, closed at both ends.
struct LoftedTorso: Sendable {
    var rings: [Ring]

    func ring(at y: Float) -> Ring {
        guard let first = rings.first, let last = rings.last else { return Ring(center: Vec3(0, y, 0), halfWidth: 0, halfDepth: 0) }
        if y <= first.center.y { return first }
        if y >= last.center.y { return last }
        var lo = 0, hi = rings.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if rings[mid].center.y <= y { lo = mid } else { hi = mid }
        }
        let a = rings[lo], b = rings[hi]
        return a.lerp(b, (y - a.center.y) / max(1e-6, b.center.y - a.center.y))
    }

    @inline(__always) func distance(_ p: Vec3) -> Float {
        let r = ring(at: p.y)
        let dx = p.x - r.center.x, dz = p.z - r.center.z
        let radial = (dx * dx + dz * dz).squareRoot()
        let across: Float = pow(abs(dx) / r.halfWidth, r.power)
        let deep: Float = pow(abs(dz) / r.halfDepth, r.power)
        let norm: Float = pow(across + deep, 1 / r.power)
        // Distance along the ray from the centre to the outline.
        let side = norm > 1e-5 ? radial * (1 - 1 / norm) : -min(r.halfWidth, r.halfDepth)
        let vertical = max(rings[0].center.y - p.y, p.y - rings[rings.count - 1].center.y)
        if vertical > 0 { return (max(side, 0) * max(side, 0) + vertical * vertical).squareRoot() }
        return max(side, vertical)
    }
}

/// Numerical gradient of a distance field, normalised.
@inline(__always) func gradient(_ f: (Vec3) -> Float, at p: Vec3, step e: Float = 0.002) -> Vec3 {
    let dx: Float = f(p + Vec3(e, 0, 0)) - f(p - Vec3(e, 0, 0))
    let dy: Float = f(p + Vec3(0, e, 0)) - f(p - Vec3(0, e, 0))
    let dz: Float = f(p + Vec3(0, 0, e)) - f(p - Vec3(0, 0, e))
    return Vec3(dx, dy, dz).normalized
}

enum SurfaceNets {
    /// The zero surface of `sdf` inside the box, sampled every `cell` metres: one vertex
    /// per cell the surface crosses (the mean of its edge crossings, then pulled onto the
    /// surface), one quad per crossed grid edge. Normals point outward.
    static func mesh(from lo: Vec3, to hi: Vec3, cell: Float, sdf: (Vec3) -> Float) -> Mesh {
        let nx = Int(((hi.x - lo.x) / cell).rounded(.up)) + 1
        let ny = Int(((hi.y - lo.y) / cell).rounded(.up)) + 1
        let nz = Int(((hi.z - lo.z) / cell).rounded(.up)) + 1
        @inline(__always) func at(_ i: Int, _ j: Int, _ k: Int) -> Vec3 {
            Vec3(lo.x + Float(i) * cell, lo.y + Float(j) * cell, lo.z + Float(k) * cell)
        }
        var values = [Float](repeating: 0, count: nx * ny * nz)
        for k in 0..<nz { for j in 0..<ny { for i in 0..<nx { values[i + nx * (j + ny * k)] = sdf(at(i, j, k)) } } }
        @inline(__always) func v(_ i: Int, _ j: Int, _ k: Int) -> Float { values[i + nx * (j + ny * k)] }

        let cx = nx - 1, cy = ny - 1, cz = nz - 1
        var cellVertex = [Int32](repeating: -1, count: cx * cy * cz)
        var mesh = Mesh()
        let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        var corner = [Float](repeating: 0, count: 8)
        for k in 0..<cz {
            for j in 0..<cy {
                for i in 0..<cx {
                    var inside = 0
                    for n in 0..<8 {
                        corner[n] = v(i + (n & 1), j + ((n >> 1) & 1), k + ((n >> 2) & 1))
                        if corner[n] < 0 { inside += 1 }
                    }
                    guard inside > 0, inside < 8 else { continue }
                    var sum = Vec3(0, 0, 0), count: Float = 0
                    for (a, b) in edges where (corner[a] < 0) != (corner[b] < 0) {
                        let t = corner[a] / (corner[a] - corner[b])
                        let pa = Vec3(Float(a & 1), Float(a >> 1 & 1), Float(a >> 2 & 1))
                        let pb = Vec3(Float(b & 1), Float(b >> 1 & 1), Float(b >> 2 & 1))
                        sum = sum + pa + (pb - pa) * t
                        count += 1
                    }
                    let local = sum * (1 / count)
                    cellVertex[i + cx * (j + cy * k)] = Int32(mesh.positions.count)
                    mesh.positions.append(at(i, j, k) + local * cell)
                }
            }
        }
        @inline(__always) func c(_ i: Int, _ j: Int, _ k: Int) -> Int32 { cellVertex[i + cx * (j + cy * k)] }
        func quad(_ q: [Int32], outwardPositive: Bool) {
            guard q.allSatisfy({ $0 >= 0 }) else { return }
            let o = outwardPositive ? q : q.reversed()
            mesh.indices += [UInt32(o[0]), UInt32(o[1]), UInt32(o[2]), UInt32(o[0]), UInt32(o[2]), UInt32(o[3])]
        }
        for k in 0..<nz {
            for j in 0..<ny {
                for i in 0..<nx {
                    let here = v(i, j, k) < 0
                    // Edge along x: the four cells around it, counter-clockwise seen from +x.
                    if i < cx, j > 0, k > 0, j < cy, k < cz, here != (v(i + 1, j, k) < 0) {
                        quad([c(i, j - 1, k - 1), c(i, j, k - 1), c(i, j, k), c(i, j - 1, k)], outwardPositive: here)
                    }
                    if j < cy, i > 0, k > 0, i < cx, k < cz, here != (v(i, j + 1, k) < 0) {
                        quad([c(i - 1, j, k - 1), c(i - 1, j, k), c(i, j, k), c(i, j, k - 1)], outwardPositive: here)
                    }
                    if k < cz, i > 0, j > 0, i < cx, j < cy, here != (v(i, j, k + 1) < 0) {
                        quad([c(i - 1, j - 1, k), c(i, j - 1, k), c(i, j, k), c(i - 1, j, k)], outwardPositive: here)
                    }
                }
            }
        }
        // Pull the vertices onto the surface and take normals from the field.
        mesh.normals = []
        for n in mesh.positions.indices {
            var p = mesh.positions[n]
            for _ in 0..<2 { p = p - gradient(sdf, at: p, step: cell * 0.3) * sdf(p) }
            mesh.positions[n] = p
            mesh.normals.append(gradient(sdf, at: p, step: cell * 0.3))
        }
        return mesh
    }
}
