import Foundation
import WearIQCore

/// The user's body as a 3D avatar built from their measurements, and a garment draped on
/// it from the fit analysis. The garment is cut to its own measurements (body girth plus
/// ease at each level, its own lengths) and then settled on the body by a cloth
/// simulation (see `ClothPiece`): where it's cut smaller than the body it has to stretch,
/// and that strain, against what the fabric can take, is the fit map. Longer than the
/// body, the extra length bunches into folds (a trouser hem stacking on the shoe, a
/// sleeve over the hand); shorter, skin shows. A shoulder seam wider than the shoulders
/// sits down the arm, and loose fabric falls in vertical folds.
///
/// Proportions not measured come from ANSUR II stature fractions: knee 0.28, armpit
/// 0.757, shoulder 0.80, neck 0.835, head centre 0.93 of stature, waist (navel) 0.601,
/// chest 0.728, hips 0.507. Units are metres, y up, the avatar facing +z.
public struct Avatar: Sendable {
    public enum Anchor: String, Sendable, CaseIterable {
        case shoulder, chest, waist, hip, thigh, sleeveEnd, hem
    }

    public var body: Mesh
    public var garment: Mesh?
    /// Where a region's label belongs on the avatar (on the garment when there is one).
    public var anchors: [Anchor: Vec3]

    /// Measurements the avatar is built from, in cm (girths are circumferences).
    public struct Measurements: Equatable, Sendable {
        public var height: Double
        public var chest: Double
        public var waist: Double
        public var hip: Double
        public var thigh: Double
        public var shoulderWidth: Double
        public var armLength: Double
        public var inseam: Double

        public init(height: Double, chest: Double, waist: Double, hip: Double, thigh: Double,
                    shoulderWidth: Double, armLength: Double, inseam: Double) {
            self.height = height; self.chest = chest; self.waist = waist; self.hip = hip; self.thigh = thigh
            self.shoulderWidth = shoulderWidth; self.armLength = armLength; self.inseam = inseam
        }

        /// From a body profile; missing values fall back to typical stature fractions.
        public init?(_ p: BodyProfile) {
            guard let h = p[.height]?.cm else { return nil }
            self.init(height: h, chest: p[.chest]?.cm ?? 0.55 * h, waist: p[.waist]?.cm ?? 0.48 * h,
                      hip: p[.hip]?.cm ?? 0.55 * h, thigh: p[.thigh]?.cm ?? 0.32 * h,
                      shoulderWidth: p[.shoulderWidth]?.cm ?? 0.23 * h, armLength: p[.armLength]?.cm ?? 0.34 * h,
                      inseam: p[.inseam]?.cm ?? 0.47 * h)
        }
    }

    /// How a garment sits, in cm: girth ease is garment minus body circumference; the
    /// deltas are how much longer (+) or shorter (−) than the body the garment is.
    public struct GarmentFit: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case top(longSleeves: Bool)
            case trousers
        }

        public var kind: Kind
        public var chestEase: Double = 10
        public var waistEase: Double = 8
        public var hipEase: Double = 8
        public var thighEase: Double = 6
        public var lengthDelta: Double = 0
        public var sleeveDelta: Double = 0
        public var shoulderDelta: Double = 0
        /// The fabric; without one, tops drape as a plain knit and trousers as a woven.
        public var fabric: Fabric?

        public init(kind: Kind) { self.kind = kind }

        var resolvedFabric: Fabric {
            if let fabric { return fabric }
            if case .trousers = kind { return .woven }
            return .knit
        }
    }

    // MARK: Building

    public init(_ m: Measurements, garment fit: GarmentFit? = nil) {
        let geo = Skeleton(m)
        body = geo.bodyMesh()
        anchors = geo.bodyAnchors
        if let fit {
            let (mesh, garmentAnchors) = geo.garmentMesh(fit)
            garment = mesh
            anchors.merge(garmentAnchors) { _, new in new }
        }
    }
}

/// Positions and sizes derived from the measurements.
private struct Skeleton {
    let m: Avatar.Measurements
    let h: Float
    let crotchY, kneeY, ankleY, hipY, waistY, chestY, armpitY, shoulderY, neckY, headY: Float
    let hip, waist, chest: (Float, Float)
    let shoulderHalf: Float
    let thighR: Float
    let legX: Float
    let armDir: (Vec3, Vec3)   // left, right
    let armStart: (Vec3, Vec3)
    let armLength: Float
    let upperArmR: Float
    /// Smoothed torso sections, crotch to neck.
    let torso: [Ring]
    /// Limb radii, top to bottom, smoothed.
    let legRadii: [Float]
    let armRadii: [Float]

    init(_ m: Avatar.Measurements) {
        self.m = m
        let h = Float(m.height / 100)
        self.h = h
        crotchY = Float(m.inseam / 100)
        kneeY = 0.28 * h
        ankleY = 0.04 * h
        hipY = max(crotchY + 0.025 * h, 0.507 * h)
        waistY = 0.601 * h
        chestY = 0.728 * h
        armpitY = 0.757 * h
        shoulderY = 0.80 * h
        neckY = 0.835 * h
        headY = 0.93 * h
        hip = Shapes.ellipse(girthCm: m.hip, depthRatio: 0.78)
        waist = Shapes.ellipse(girthCm: m.waist, depthRatio: 0.75)
        chest = Shapes.ellipse(girthCm: m.chest, depthRatio: 0.72)
        shoulderHalf = Float(m.shoulderWidth / 200) * 1.08
        thighR = Float(m.thigh / 100) / (2 * .pi)
        legX = hip.0 * 0.5
        // Arms hang about 12° out from the body.
        let angle: Float = 12 * .pi / 180
        armDir = (Vec3(sin(angle), -cos(angle), 0), Vec3(-sin(angle), -cos(angle), 0))
        armStart = (Vec3(shoulderHalf * 0.92, shoulderY - 0.01 * h, 0), Vec3(-shoulderHalf * 0.92, shoulderY - 0.01 * h, 0))
        armLength = Float(m.armLength / 100)
        upperArmR = 0.0275 * h

        // Key sections: superellipses a little boxier than an ellipse through the chest
        // and shoulders, the seat set back and the chest forward, each measured level
        // scaled to its exact girth; Catmull–Rom smoothing flows between them.
        func key(_ y: Float, _ size: (Float, Float), z: Float = 0, power: Float = 2.2, girth: Double? = nil) -> Ring {
            let ring = Ring(center: Vec3(0, y, z * h), halfWidth: size.0, halfDepth: size.1, power: power)
            return girth.map { ring.scaled(toPerimeter: Float($0 / 100)) } ?? ring
        }
        let keys = [
            key(crotchY, (hip.0 * 0.9, hip.1 * 0.8), z: -0.004, power: 2.1),
            key(hipY, hip, z: -0.008, power: 2.3, girth: m.hip),
            key((hipY + waistY) / 2, ((hip.0 + waist.0) / 2, (hip.1 + waist.1) / 2), z: -0.004, power: 2.3, girth: (m.hip + m.waist) / 2),
            key(waistY, waist, power: 2.2, girth: m.waist),
            key((waistY + chestY) / 2, ((waist.0 + chest.0) / 2, (waist.1 + chest.1) / 2), z: 0.002, power: 2.3,
                girth: (m.waist + m.chest) / 2),
            key(chestY, chest, z: 0.004, power: 2.4, girth: m.chest),
            key(armpitY, (chest.0 * 0.97, chest.1 * 0.93), z: 0.002, power: 2.6),
            key(shoulderY - 0.012 * h, (shoulderHalf * 0.96, chest.1 * 0.74), power: 2.8),
            key(shoulderY + 0.012 * h, (shoulderHalf * 0.78, chest.1 * 0.6), z: -0.004, power: 2.5),
            key(0.826 * h, (shoulderHalf * 0.42, chest.1 * 0.45), z: -0.004),
            key(neckY, (0.033 * h, 0.035 * h), z: -0.002, power: 2),
        ]
        torso = Shapes.smooth(keys)
        // Thigh to ankle with the knee narrowing and the calf filling out again.
        legRadii = Shapes.smoothRadii([1, 0.9, 0.78, 0.63, 0.66, 0.6, 0.46, 0.38].map { [thighR] in $0 * thighR })
        // Deltoid, biceps, elbow, forearm, wrist.
        armRadii = Shapes.smoothRadii([1.08, 1, 0.93, 0.8, 0.82, 0.72, 0.56].map { [upperArmR] in $0 * upperArmR })
    }

    // MARK: Body

    private var legs: [(top: Vec3, bottom: Vec3)] {
        [1, -1].map { (side: Float) in
            (Vec3(side * legX, crotchY + 0.01 * h, 0), Vec3(side * legX * 0.85, ankleY, 0))
        }
    }

    private var arms: [(start: Vec3, dir: Vec3)] { [(armStart.0, armDir.0), (armStart.1, armDir.1)] }

    private func radius(_ radii: [Float], at f: Float) -> Float {
        let x = min(1, max(0, f)) * Float(radii.count - 1)
        let k = min(radii.count - 2, Int(x))
        return radii[k] + (radii[k + 1] - radii[k]) * (x - Float(k))
    }

    func bodyMesh() -> Mesh {
        var mesh = Shapes.loft(torso)
        // Neck, skull and jaw.
        mesh.append(Shapes.tube(from: Vec3(0, neckY - 0.012 * h, -0.002 * h), to: Vec3(0, headY - 0.035 * h, 0.002 * h),
                                radii: [0.033 * h, 0.03 * h, 0.029 * h]))
        mesh.append(Shapes.ellipsoid(center: Vec3(0, headY + 0.01 * h, 0), radii: Vec3(0.044 * h, 0.058 * h, 0.052 * h)))
        mesh.append(Shapes.ellipsoid(center: Vec3(0, headY - 0.03 * h, 0.012 * h), radii: Vec3(0.036 * h, 0.036 * h, 0.04 * h)))
        // Legs, ankles and feet.
        for leg in legs {
            mesh.append(Shapes.tube(from: leg.top, to: leg.bottom, radii: legRadii))
            mesh.append(Shapes.ellipsoid(center: leg.bottom, radii: Vec3(repeating: legRadii.last ?? 0.02)))
            let heel = Vec3(leg.bottom.x, 0.022 * h, -0.035 * h), toe = Vec3(leg.bottom.x, 0.016 * h, 0.115 * h)
            mesh.append(Shapes.tube(from: heel, to: toe, radii: Shapes.smoothRadii([0.018, 0.024, 0.028, 0.027, 0.016].map { $0 * h }),
                                    flatten: 0.55))
        }
        // Shoulders, arms and hands.
        for arm in arms {
            let wrist = arm.start + arm.dir * armLength
            mesh.append(Shapes.ellipsoid(center: arm.start, radii: Vec3(upperArmR * 1.12, upperArmR * 1.2, upperArmR * 1.08)))
            mesh.append(Shapes.tube(from: arm.start, to: wrist, radii: armRadii))
            mesh.append(Shapes.tube(from: wrist - arm.dir * (0.005 * h), to: wrist + arm.dir * (0.105 * h),
                                    radii: Shapes.smoothRadii([0.016, 0.024, 0.025, 0.022, 0.012].map { $0 * h }), flatten: 0.45))
        }
        return mesh
    }

    var bodyAnchors: [Avatar.Anchor: Vec3] {
        [
            .shoulder: Vec3(shoulderHalf, shoulderY, 0), .chest: Vec3(chest.0, chestY, 0),
            .waist: Vec3(waist.0, waistY, 0), .hip: Vec3(hip.0, hipY, 0),
            .thigh: Vec3(legX + thighR, crotchY - 0.03 * h, 0),
        ]
    }

    /// The body as the cloth sees it.
    private var collider: BodyCollider {
        var c = BodyCollider()
        c.torso = torso
        return c
    }

    private func limbCollider(_ a: Vec3, _ b: Vec3, _ radii: [Float]) -> BodyCollider {
        var c = BodyCollider()
        c.limbs = [(a, b, radii)]
        return c
    }

    // MARK: Garment

    /// The torso section at a height, the body's own shape there.
    private func bodyRing(at y: Float) -> Ring {
        var ring = collider.torsoRing(at: y)!
        ring.center.y = y
        return ring
    }

    /// Value at `y` interpolated through (height, value) keys; flat beyond them.
    private func interpolate(_ keys: [(Float, Float)], at y: Float) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if y <= first.0 { return first.1 }
        if y >= last.0 { return last.1 }
        for (a, b) in zip(keys, keys.dropFirst()) where y <= b.0 {
            return a.1 + (b.1 - a.1) * (y - a.0) / (b.0 - a.0)
        }
        return last.1
    }

    /// A torso panel from `bottom` to `top`: at each body section, the garment's cut is
    /// the body's shape scaled to the body's girth plus `ease` (m), widened by `widen`.
    private func torsoPanel(from bottom: Float, to top: Float, ease: (Float) -> Float,
                            widen: (Float) -> Float = { _ in 0 }) -> (ClothPiece, [Float]) {
        // Evenly spaced rings, about 1.5 cm apart.
        let count = max(2, Int(((top - bottom) / 0.015).rounded()) + 1)
        let levels = (0..<count).map { bottom + (top - bottom) * Float($0) / Float(count - 1) }
        var rings: [[Vec3]] = [], centers: [Vec3] = [], slack: [Float] = []
        for y in levels {
            let body = bodyRing(at: y)
            let e = ease(y)
            var cut = body.scaled(toPerimeter: max(0.3 * body.perimeter, body.perimeter + e))
            cut.halfWidth += widen(y)
            rings.append((0..<Shapes.segments).map { cut.point(Float($0) / Float(Shapes.segments) * 2 * .pi) })
            centers.append(cut.center)
            slack.append(e)
        }
        return (ClothPiece(rings: rings, centers: centers), slack)
    }

    /// A tube panel through (centre, radius) stations, round in the frame of `a`→`b`.
    private func tubePanel(_ stations: [(Vec3, Float)], frame: (u: Vec3, v: Vec3)) -> ClothPiece {
        let rings = stations.map { c, r in
            (0..<Shapes.segments).map { i -> Vec3 in
                let t = Float(i) / Float(Shapes.segments) * 2 * .pi
                return c + frame.u * (r * cos(t)) + frame.v * (r * sin(t))
            }
        }
        return ClothPiece(rings: rings, centers: stations.map(\.0))
    }

    /// The point of a ring furthest out to the side (+x), for labels.
    private func edge(_ piece: ClothPiece, ring r: Int) -> Vec3 {
        piece.positions[(r * piece.n)..<((r + 1) * piece.n)].max { $0.x < $1.x } ?? piece.centers[r]
    }

    private func nearestRing(_ piece: ClothPiece, to y: Float) -> Int {
        piece.centers.indices.min { abs(piece.centers[$0].y - y) < abs(piece.centers[$1].y - y) } ?? 0
    }

    func garmentMesh(_ fit: Avatar.GarmentFit) -> (Mesh, [Avatar.Anchor: Vec3]) {
        let fabric = fit.resolvedFabric
        func cm(_ v: Double) -> Float { Float(v / 100) }
        var mesh = Mesh()
        var anchors: [Avatar.Anchor: Vec3] = [:]

        func settle(_ piece: inout ClothPiece, on body: BodyCollider, pinned: Set<Int>, slack: (Int) -> Float) {
            piece.drape(on: body, fabric: fabric, pinned: pinned)
            piece.addDrapeFolds(slack: slack, fabric: fabric)
            mesh.append(piece.mesh(fabric: fabric))
        }

        switch fit.kind {
        case .trousers:
            let waistband = (waistY + hipY) / 2
            let ease = { (y: Float) in self.interpolate([(self.hipY, cm(fit.hipEase)), (waistband, cm(fit.waistEase))], at: y) }
            var (seat, seatSlack) = torsoPanel(from: crotchY - 0.01 * h, to: waistband, ease: ease)
            settle(&seat, on: collider, pinned: [seat.ringCount - 1]) { seatSlack[$0] }
            anchors[.waist] = edge(seat, ring: seat.ringCount - 1)
            anchors[.hip] = edge(seat, ring: nearestRing(seat, to: hipY))

            // Longer than the leg: the hem reaches the floor and the rest stacks in folds.
            // Shorter: the hem sits above the ankle.
            let extra = cm(fit.lengthDelta)
            let hemY = extra >= 0 ? max(0.012 * h, ankleY - extra) : ankleY - extra
            let stacked = max(0, extra - (ankleY - 0.012 * h))
            let folds = min(5, Int((stacked * 100 / 1.8).rounded(.up)))
            let stack = Float(folds) * 0.018
            let thighOff = max(-0.01, cm(fit.thighEase) / (2 * .pi))
            for leg in legs {
                let top = Vec3(leg.top.x, crotchY + 0.005 * h, 0)
                let bottom = Vec3(leg.bottom.x, hemY, 0)
                let legSpan = leg.top.y - leg.bottom.y
                func station(_ y: Float) -> (Vec3, Float) {
                    let f = (top.y - y) / (top.y - bottom.y)
                    let c = top + (bottom - top) * f
                    return (c, radius(legRadii, at: (leg.top.y - y) / legSpan) + thighOff * (1 - 0.3 * f) + 0.006)
                }
                var stations = (0...16).map { station(top.y - (top.y - hemY - stack) * Float($0) / 16) }
                let base = stations.last!.1
                for j in stride(from: 1, through: folds * 2, by: 1) {
                    let y = hemY + stack - stack * Float(j) / Float(folds * 2)
                    stations.append((station(y).0, base * (j % 2 == 1 ? 1.35 : 1)))
                }
                var piece = tubePanel(stations, frame: Shapes.frame(leg.top, leg.bottom))
                var body = limbCollider(leg.top, leg.bottom, legRadii)
                body.limbs.append((Vec3(leg.bottom.x, 0.018 * h, -0.03 * h), Vec3(leg.bottom.x, 0.014 * h, 0.11 * h), [0.017 * h]))
                let legSlack = stations.map { 2 * .pi * max(0, $0.1 - self.radius(legRadii, at: (leg.top.y - $0.0.y) / legSpan)) }
                settle(&piece, on: body, pinned: [0]) { legSlack[$0] }
                if leg.top.x > 0 { anchors[.hem] = edge(piece, ring: piece.ringCount - 1) }
            }

        case let .top(longSleeves):
            // A regular top ends just below the hips; longer or shorter moves the hem.
            let hemY = max(0.38 * h, crotchY + 0.035 * h - cm(fit.lengthDelta))
            let dropped = Float(max(0, fit.shoulderDelta) / 200)
            let chestE = cm(fit.chestEase)
            // The yoke rests on the shoulders, always just clear of them.
            let ease = { (y: Float) -> Float in
                let e = self.interpolate([(self.hipY, cm(max(fit.hipEase, fit.waistEase))), (self.waistY, cm(fit.waistEase)),
                                  (self.chestY, chestE), (self.armpitY, chestE), (self.shoulderY, chestE * 0.5),
                                  (self.neckY, 0.015)], at: y)
                return y >= self.shoulderY - 0.005 * self.h ? max(e, 0.012) : e
            }
            let widen = { (y: Float) in dropped * max(0, 1 - abs(y - self.shoulderY) / (0.04 * self.h)) }
            var (shell, shellSlack) = torsoPanel(from: hemY, to: neckY - 0.004 * h, ease: ease, widen: widen)
            // Loose fabric only falls into folds below the chest, where nothing holds it.
            let foldSlack = shell.centers.indices.map { shell.centers[$0].y < chestY ? shellSlack[$0] : 0 }
            let yoke = Set(shell.centers.indices.filter { shell.centers[$0].y >= shoulderY - 0.005 * h })
            settle(&shell, on: collider, pinned: yoke) { foldSlack[$0] }
            anchors[.hem] = edge(shell, ring: 0)
            anchors[.chest] = edge(shell, ring: nearestRing(shell, to: chestY))
            anchors[.waist] = edge(shell, ring: nearestRing(shell, to: waistY))
            anchors[.shoulder] = Vec3(shoulderHalf + dropped, shoulderY, 0)

            // Sleeves start at the shoulder seam: down the arm when the shoulder is dropped.
            let sleeveLength = longSleeves ? armLength + cm(fit.sleeveDelta) : 0.36 * armLength
            let reach = min(sleeveLength, armLength + 0.04 * h)
            let overHand = max(0, sleeveLength - armLength)
            let folds = longSleeves ? min(4, Int((overHand * 100 / 1.5).rounded(.up))) : 0
            let stack = Float(folds) * 0.012
            let sleeveEase = upperArmR * 0.35 + max(0, chestE / (2 * .pi)) * 0.4
            for arm in arms {
                func station(_ s: Float) -> (Vec3, Float) {
                    (arm.start + arm.dir * s, radius(armRadii, at: s / armLength) + sleeveEase)
                }
                var stations = (0...12).map { station(dropped + (reach - stack - dropped) * Float($0) / 12) }
                let base = stations.last!.1
                for j in stride(from: 1, through: folds * 2, by: 1) {
                    stations.append((station(reach - stack + stack * Float(j) / Float(folds * 2)).0, base * (j % 2 == 1 ? 1.3 : 1)))
                }
                let wrist = arm.start + arm.dir * armLength
                var piece = tubePanel(stations, frame: Shapes.frame(arm.start, wrist))
                var body = limbCollider(arm.start, wrist, armRadii)
                body.limbs.append((wrist, wrist + arm.dir * (0.1 * h), [0.02 * h, 0.012 * h]))
                body.floorY = -1
                settle(&piece, on: body, pinned: [0]) { _ in 0 }
                if anchors[.sleeveEnd] == nil { anchors[.sleeveEnd] = piece.centers[piece.ringCount - 1] }
            }
        }
        return (mesh, anchors)
    }
}

private extension Vec3 {
    init(repeating v: Float) { self.init(v, v, v) }
}
