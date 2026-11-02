import Foundation

/// The person's own pixels in a segmentation mask. The person segmentation sometimes
/// takes in what touches or stands behind someone, such as a chair back, a coat on a
/// rack or a door frame, and the measured widths and the live outline with it. Only
/// what joins the skeleton and lies within reach of its bones stays: round each bone a
/// capsule as wide as a body of this size can be there (from the neck-to-hip length, so
/// it scales with distance), with room for loose clothes, skirts and hair. Without
/// joints, the largest blob.
extension BinaryMask {
    public func isolatingPerson(joints: [BodyJoint: Point2D]) -> BinaryMask {
        guard let envelope = PersonEnvelope(joints: joints, height: height) else { return largestComponent() }
        var keep = [Bool](repeating: false, count: width * height)
        var allowed = [Int8](repeating: -1, count: width * height)
        func inside(_ x: Int, _ y: Int) -> Bool {
            let i = y * width + x
            if allowed[i] < 0 { allowed[i] = envelope.contains(Double(x) + 0.5, Double(y) + 0.5) ? 1 : 0 }
            return allowed[i] == 1
        }
        var stack: [Int] = []
        for seed in envelope.seeds {
            let x = Int(seed.x), y = Int(seed.y)
            guard x >= 0, y >= 0, x < width, y < height, self[x, y], !keep[y * width + x] else { continue }
            keep[y * width + x] = true
            stack.append(y * width + x)
        }
        guard !stack.isEmpty else { return largestComponent() }
        while let i = stack.popLast() {
            let x = i % width, y = i / width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let j = ny * width + nx
                guard !keep[j], self[nx, ny], inside(nx, ny) else { continue }
                keep[j] = true
                stack.append(j)
            }
        }
        return BinaryMask(width: width, height: height, bits: keep)
    }

    /// The biggest 4-connected blob.
    public func largestComponent() -> BinaryMask {
        var label = [Int32](repeating: 0, count: width * height)
        var best = (id: Int32(0), size: 0)
        var next: Int32 = 0
        var stack: [Int] = []
        for start in 0..<(width * height) where label[start] == 0 && self[start % width, start / width] {
            next += 1
            label[start] = next
            stack.append(start)
            var size = 0
            while let i = stack.popLast() {
                size += 1
                let x = i % width, y = i / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < width, ny < height, self[nx, ny] else { continue }
                    let j = ny * width + nx
                    guard label[j] == 0 else { continue }
                    label[j] = next
                    stack.append(j)
                }
            }
            if size > best.size { best = (next, size) }
        }
        guard best.size > 0 else { return self }
        return BinaryMask(width: width, height: height, bits: label.map { $0 == best.id })
    }
}

/// Capsules round the skeleton's bones, in mask pixels.
struct PersonEnvelope {
    struct Capsule {
        var a: Point2D, b: Point2D, r: Double

        func contains(_ x: Double, _ y: Double) -> Bool {
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / len2)) : 0
            let px = a.x + t * dx - x, py = a.y + t * dy - y
            return px * px + py * py <= r * r
        }
    }

    var capsules: [Capsule] = []
    var seeds: [Point2D] = []

    init?(joints j: [BodyJoint: Point2D], height: Int) {
        // The body's scale: neck to hips, or the span of what was found.
        let scale: Double
        if let neck = j[.neck], let root = j[.root], neck.distance(to: root) > 8 {
            scale = neck.distance(to: root)
        } else {
            let ys = j.values.map(\.y)
            guard let lo = ys.min(), let hi = ys.max(), hi - lo > 24 else { return nil }
            scale = (hi - lo) / 3
        }
        func add(_ a: BodyJoint, _ b: BodyJoint, _ r: Double) {
            guard let p = j[a], let q = j[b] else { return }
            capsules.append(Capsule(a: p, b: q, r: r * scale))
        }
        func extend(_ from: BodyJoint, _ to: BodyJoint, by f: Double, _ r: Double) {
            guard let p = j[from], let q = j[to] else { return }
            let end = Point2D(q.x + (q.x - p.x) * f, q.y + (q.y - p.y) * f)
            capsules.append(Capsule(a: q, b: end, r: r * scale))
        }
        // Torso: wide enough for a heavy body seen from the side, or a loose coat.
        add(.neck, .root, 0.55)
        add(.leftShoulder, .rightShoulder, 0.4)
        add(.leftHip, .rightHip, 0.5)
        add(.root, .leftHip, 0.5)
        add(.root, .rightHip, 0.5)
        add(.neck, .leftShoulder, 0.4)
        add(.neck, .rightShoulder, 0.4)
        // Head and hair, to the crown.
        add(.neck, .nose, 0.5)
        extend(.neck, .nose, by: 1.1, 0.5)
        for side in [(BodyJoint.leftShoulder, BodyJoint.leftElbow, BodyJoint.leftWrist),
                     (.rightShoulder, .rightElbow, .rightWrist)] {
            if j[side.1] != nil {
                add(side.0, side.1, 0.26)
                add(side.1, side.2, 0.23)
                // The hand past the wrist.
                extend(side.1, side.2, by: 0.45, 0.22)
            } else if let shoulder = j[side.0] {
                // An arm the pose didn't find: anywhere it can reach.
                capsules.append(Capsule(a: shoulder, b: shoulder, r: 1.25 * scale))
            }
        }
        let floor = Double(height)
        for side in [(BodyJoint.leftHip, BodyJoint.leftKnee, BodyJoint.leftAnkle),
                     (.rightHip, .rightKnee, .rightAnkle)] {
            if j[side.1] != nil {
                add(side.0, side.1, 0.4)
                add(side.1, side.2, 0.32)
                // The foot, down to the floor.
                if let ankle = j[side.2] {
                    capsules.append(Capsule(a: ankle, b: Point2D(ankle.x, min(floor, ankle.y + 0.35 * scale)), r: 0.32 * scale))
                }
            } else if let hip = j[side.0] ?? j[.root] {
                capsules.append(Capsule(a: hip, b: Point2D(hip.x, floor), r: 0.5 * scale))
            }
        }
        // A skirt, a dress or a coat hangs round both legs together.
        if let root = j[.root] {
            let knees = [j[.leftKnee], j[.rightKnee]].compactMap { $0 }
            let ankles = [j[.leftAnkle], j[.rightAnkle]].compactMap { $0 }
            if !knees.isEmpty {
                let knee = Point2D(knees.map(\.x).reduce(0, +) / Double(knees.count), knees.map(\.y).reduce(0, +) / Double(knees.count))
                capsules.append(Capsule(a: root, b: knee, r: 0.6 * scale))
                if !ankles.isEmpty {
                    let ankle = Point2D(ankles.map(\.x).reduce(0, +) / Double(ankles.count),
                                        ankles.map(\.y).reduce(0, +) / Double(ankles.count))
                    capsules.append(Capsule(a: knee, b: ankle, r: 0.5 * scale))
                }
            }
        }
        guard !capsules.isEmpty else { return nil }
        // Flood starts on the bones themselves.
        for c in capsules {
            for k in 0...8 {
                let t = Double(k) / 8
                seeds.append(Point2D(c.a.x + (c.b.x - c.a.x) * t, c.a.y + (c.b.y - c.a.y) * t))
            }
        }
    }

    func contains(_ x: Double, _ y: Double) -> Bool {
        capsules.contains { $0.contains(x, y) }
    }
}
