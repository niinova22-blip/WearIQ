import Foundation
import WearIQCore

/// The user's body as a 3D avatar built from their measurements, and a garment draped on
/// it from the fit analysis.
///
/// The body is one smooth surface: a torso lofted through sections scaled to the
/// measured girths, with neck, head, arms, hands, legs and feet blended into it as
/// distance fields, so shoulders, hips and joints flow without seams. The garment is cut
/// as an offset of the body parts it covers (body girth plus the garment's ease at each
/// level, its own lengths, open at hem, cuffs, neckline and waistband) and then settled
/// on the body by a cloth simulation (`TriangleCloth`): where it's cut smaller than the
/// body it stretches, and that strain, against what the fabric can take, plus where it
/// rests on the body, is the fit map. Extra length bunches at hems and cuffs, loose
/// fabric falls in vertical folds, and seams are stitched in where a garment has them.
///
/// Proportions not measured come from ANSUR II stature fractions: knee 0.28, armpit
/// 0.757, shoulder 0.80, neck 0.835, head centre 0.93 of stature, waist (navel) 0.601,
/// chest 0.728, hips 0.507. Units are metres, y up, the avatar facing +z.
public struct Avatar: Sendable {
    public enum Anchor: String, Sendable, CaseIterable {
        case shoulder, chest, waist, hip, thigh, sleeveEnd, hem
    }

    /// A body point worth naming on screen.
    public struct Landmark: Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            case neck, shoulder, chest, elbow, waist, wrist, hip, crotch, thigh, knee, ankle
        }
        public var kind: Kind
        /// On the outside surface (the garment's, where it covers the point).
        public var position: Vec3
        /// Surface normal there, to tell whether it faces the camera.
        public var normal: Vec3
        /// Which way the label goes: +1 towards the avatar's left (+x), −1 its right.
        public var side: Float
    }

    /// One garment worn on the avatar.
    public struct Layer: Sendable {
        public var fit: GarmentFit
        public var mesh: Mesh
        /// Vertex positions as it is put on: dropped onto the body, falling under gravity
        /// and settling, at 30 frames a second; the last is `mesh`. Empty unless the
        /// detail asks for it.
        public var frames: [[Vec3]] = []
        /// Stitch lines (hems, cuffs, side and shoulder seams), as dash segments: pairs of points.
        public var seams: [Vec3] = []
        /// Where its seams and hems sit against the body.
        public var fitLines: [FitLine] = []
        /// How it sits in each zone, from the drape.
        public var fitReport: [FitZone: ZoneReport] = [:]
    }

    public var body: Mesh
    /// The garments worn, in the order given; at most a top and trousers. Trousers are
    /// put on first and the top over them.
    public var layers: [Layer] = []
    public var landmarks: [Landmark] = []
    /// Where a region's label belongs on the avatar (on the first garment when there is one).
    public var anchors: [Anchor: Vec3]

    /// The first garment.
    public var garment: Mesh? { layers.first?.mesh }
    public var garmentFrames: [[Vec3]] { layers.first?.frames ?? [] }
    public var seams: [Vec3] { layers.first?.seams ?? [] }
    public var fitReport: [FitZone: ZoneReport] { layers.first?.fitReport ?? [:] }

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

    /// Mesh resolution: grid cell size in metres for the body and the garment.
    public struct Detail: Sendable {
        public var body: Float
        public var garment: Float
        /// Simulate the garment being put on and keep the frames (slower).
        public var animated = false
        public static let standard = Detail(body: 0.011, garment: 0.014)
        public static let preview = Detail(body: 0.02, garment: 0.022)
        /// Standard resolution, with the dressing animation.
        public static let animated = Detail(body: 0.011, garment: 0.014, animated: true)
    }

    // MARK: Building

    public init(_ m: Measurements, garment fit: GarmentFit? = nil, detail: Detail = .standard) {
        self.init(m, garments: fit.map { [$0] } ?? [], detail: detail)
    }

    /// Dressed in several garments: trousers first, then a top over them, resting on the
    /// trousers where it covers them.
    public init(_ m: Measurements, garments: [GarmentFit], detail: Detail = .standard) {
        let model = BodyModel.make(m)
        body = model.mesh(cell: detail.body)
        anchors = model.bodyAnchors
        let order = garments.indices.sorted { a, b in
            func inner(_ i: Int) -> Int { if case .trousers = garments[i].kind { return 0 }; return 1 }
            return inner(a) < inner(b)
        }
        var cover: ((Vec3) -> Float)?
        var dressed: [Int: BodyModel.Dressed] = [:]
        for i in order {
            let d = model.dress(garments[i], cell: detail.garment, animated: detail.animated, under: cover)
            dressed[i] = d
            let cut = d.cut
            cover = cover.map { previous in { p in min(previous(p), cut(p)) } } ?? cut
        }
        for i in garments.indices.reversed() {
            guard let d = dressed[i] else { continue }
            anchors.merge(d.anchors) { _, new in new }
        }
        layers = garments.indices.compactMap { i in
            dressed[i].map { Layer(fit: garments[i], mesh: $0.mesh, frames: $0.frames, seams: $0.seams,
                                   fitLines: $0.lines, fitReport: $0.report) }
        }
        landmarks = model.landmarks(covering: cover)
    }

    /// The first garment as it was at one frame of its dressing, for playing it back;
    /// the finished garment when there is no such frame.
    public func garmentMesh(frame: Int) -> Mesh? {
        layers.first.flatMap { layerMesh($0, frame: frame) }
    }

    /// A garment as it was at one frame of its dressing; the finished one past the end.
    public func layerMesh(_ layer: Layer, frame: Int) -> Mesh {
        var mesh = layer.mesh
        guard layer.frames.indices.contains(frame), layer.frames[frame].count == mesh.positions.count else { return mesh }
        mesh.positions = layer.frames[frame]
        mesh.computeNormals()
        return mesh
    }
}

/// Positions, sizes and the body's distance field, from the measurements.
struct BodyModel: Sendable {
    let m: Avatar.Measurements
    let h: Float
    let crotchY, kneeY, ankleY, hipY, waistY, chestY, armpitY, shoulderY, neckY, headY: Float
    let hip, waist, chest: (Float, Float)
    let shoulderHalf, thighR, legX, armLength, upperArmR: Float
    let torso: LoftedTorso
    let neck: Bone
    let skull, jaw: Ellipsoid
    /// Left (+x) then right.
    let arms: [(start: Vec3, dir: Vec3, limb: Limb, hand: Ellipsoid)]
    let legs: [(hip: Vec3, knee: Vec3, ankle: Vec3, limb: Limb, foot: Ellipsoid)]
    /// The skin to show, when the body comes from the SOMA shape model; otherwise the
    /// distance field's surface is shown.
    let surface: Mesh?
    /// Box around the whole body.
    let bounds: (Vec3, Vec3)
    /// Where a top's neckline is cut: points with normal·p above offset are open. Lower
    /// at the front than at the back, as a crew neck is.
    let neckline: (normal: Vec3, offset: Float)
    /// The neckline's highest point, at the back.
    let necklineTop: Float
    /// How far garments are kept off the skin: a few millimetres over a scanned body's
    /// coarse triangles, which would otherwise poke through fabric resting on them.
    let skinMargin: Float

    /// From the SOMA shape model when it's bundled, otherwise drawn from the measurements.
    static func make(_ m: Avatar.Measurements) -> BodyModel {
        SomaModel.shared.map { BodyModel(soma: $0, m) } ?? BodyModel(m)
    }

    init(_ m: Avatar.Measurements) {
        self.m = m
        surface = nil
        let h = Float(m.height / 100)
        self.h = h
        let crotchY = Float(m.inseam / 100)
        let hipY = max(crotchY + 0.025 * h, 0.507 * h)
        let waistY = 0.601 * h, chestY = 0.728 * h, armpitY = 0.757 * h
        let shoulderY = 0.80 * h, neckY = 0.835 * h, headY = 0.93 * h
        self.crotchY = crotchY
        kneeY = 0.28 * h
        ankleY = 0.04 * h
        self.hipY = hipY; self.waistY = waistY; self.chestY = chestY; self.armpitY = armpitY
        self.shoulderY = shoulderY; self.neckY = neckY; self.headY = headY
        let hip = Shapes.ellipse(girthCm: m.hip, depthRatio: 0.78)
        let waist = Shapes.ellipse(girthCm: m.waist, depthRatio: 0.75)
        let chest = Shapes.ellipse(girthCm: m.chest, depthRatio: 0.72)
        self.hip = hip; self.waist = waist; self.chest = chest
        let shoulderHalf = Float(m.shoulderWidth / 200) * 1.08
        self.shoulderHalf = shoulderHalf
        let thighR = Float(m.thigh / 100) / (2 * .pi)
        self.thighR = thighR
        // Thighs as wide as the hips allow: the outer thigh stays inside the hip line.
        let legX = max(hip.0 - thighR * 1.05, thighR * 0.75)
        self.legX = legX
        let armLength = Float(m.armLength / 100)
        self.armLength = armLength
        let u = 0.0265 * h
        upperArmR = u

        // Key sections: superellipses a little fuller than an ellipse through the chest
        // and shoulders, the seat set back and the chest forward, each measured level
        // scaled to its exact girth; Catmull–Rom smoothing flows between them.
        func key(_ y: Float, _ size: (Float, Float), z: Float = 0, power: Float = 2.2, girth: Double? = nil) -> Ring {
            let ring = Ring(center: Vec3(0, y, z * h), halfWidth: size.0, halfDepth: size.1, power: power)
            guard let girth else { return ring }
            return ring.scaled(toPerimeter: Float(girth / 100))
        }
        let keys: [Ring] = [
            key(crotchY - 0.01 * h, (hip.0 * 0.55, hip.1 * 0.6), z: -0.004, power: 2.1),
            key(crotchY + 0.012 * h, (hip.0 * 0.95, hip.1 * 0.9), z: -0.007, power: 2.2),
            key(hipY, hip, z: -0.008, power: 2.15, girth: m.hip),
            key((hipY + waistY) / 2, ((hip.0 + waist.0) / 2, (hip.1 + waist.1) / 2), z: -0.004, power: 2.15,
                girth: (m.hip + m.waist) / 2),
            key(waistY, waist, power: 2.1, girth: m.waist),
            key((waistY + chestY) / 2, ((waist.0 + chest.0) / 2, (waist.1 + chest.1) / 2), z: 0.002, power: 2.15,
                girth: (m.waist + m.chest) / 2),
            key(chestY, chest, z: 0.004, power: 2.2, girth: m.chest),
            key(armpitY, (chest.0 * 0.96, chest.1 * 0.93), z: 0.002, power: 2.35),
            // The shoulders slope from the neck to the shoulder points (trapezius), and the
            // deltoids round them off below: no level shelf with a ball at each end.
            key(shoulderY - 0.03 * h, (shoulderHalf * 0.86, chest.1 * 0.72), power: 2.3),
            key(shoulderY - 0.006 * h, (shoulderHalf * 0.76, chest.1 * 0.6), z: -0.003, power: 2.4),
            key(shoulderY + 0.012 * h, (shoulderHalf * 0.52, chest.1 * 0.5), z: -0.004, power: 2.2),
            key(0.826 * h, (shoulderHalf * 0.3, chest.1 * 0.43), z: -0.004),
            key(neckY, (0.032 * h, 0.034 * h), z: -0.003, power: 2),
        ]
        torso = LoftedTorso(rings: Shapes.smooth(keys))
        neck = Bone(a: Vec3(0, neckY - 0.02 * h, -0.004 * h), b: Vec3(0, headY - 0.045 * h, 0.002 * h), ra: 0.031 * h, rb: 0.028 * h)
        skull = Ellipsoid(center: Vec3(0, headY + 0.008 * h, -0.002 * h), radii: Vec3(0.044 * h, 0.059 * h, 0.053 * h))
        jaw = Ellipsoid(center: Vec3(0, headY - 0.03 * h, 0.012 * h), radii: Vec3(0.034 * h, 0.032 * h, 0.04 * h))

        // Arms hang about 16° out from the body.
        let angle: Float = 16 * .pi / 180
        arms = [Float(1), -1].map { side in
            // The arm's axis starts inside the shoulder, so the top of the deltoid meets the
            // slope of the shoulder instead of standing above it.
            let start = Vec3(side * shoulderHalf * 0.82, shoulderY - 0.03 * h, -0.004 * h)
            let dir = Vec3(side * sin(angle), -cos(angle), 0)
            func at(_ f: Float) -> Vec3 { start + dir * (armLength * f) }
            let limb = Limb(bones: [
                Bone(a: start, b: at(0.12), ra: u * 1.02, rb: u * 1.03),   // deltoid
                Bone(a: at(0.12), b: at(0.36), ra: u * 1.04, rb: u * 0.95),  // biceps
                Bone(a: at(0.36), b: at(0.55), ra: u * 0.95, rb: u * 0.74),  // elbow
                Bone(a: at(0.55), b: at(0.68), ra: u * 0.76, rb: u * 0.8),   // forearm
                Bone(a: at(0.68), b: at(1), ra: u * 0.8, rb: u * 0.55),     // wrist
            ], blend: 0.006 * h)
            let across = Vec3(dir.y, -dir.x, 0)
            let hand = Ellipsoid(center: at(1) + dir * (0.05 * h), radii: Vec3(0.012 * h, 0.052 * h, 0.024 * h),
                                 frame: (across, dir, Vec3(0, 0, 1)))
            return (start, dir, limb, hand)
        }
        legs = [Float(1), -1].map { side in
            let top = Vec3(side * legX, crotchY + 0.02 * h, -0.004 * h)
            // A slight A-stance, feet a little apart, as body scanners pose the avatar.
            let knee = Vec3(side * legX * 1.12, 0.28 * h, 0.004 * h)
            let ankle = Vec3(side * legX * 1.15, 0.04 * h, -0.006 * h)
            func thigh(_ f: Float) -> Vec3 { top + (knee - top) * f }
            func shank(_ f: Float) -> Vec3 { knee + (ankle - knee) * f + Vec3(0, 0, -0.008 * h * sin(f * .pi)) }
            let r = thighR
            let limb = Limb(bones: [
                Bone(a: top, b: thigh(0.12), ra: r * 0.82, rb: r * 1.0),
                Bone(a: thigh(0.12), b: thigh(0.3), ra: r * 1.0, rb: r * 0.95),
                Bone(a: thigh(0.3), b: thigh(0.62), ra: r * 0.95, rb: r * 0.8),
                Bone(a: thigh(0.62), b: knee, ra: r * 0.8, rb: r * 0.6),
                Bone(a: knee, b: shank(0.28), ra: r * 0.6, rb: r * 0.64),   // calf
                Bone(a: shank(0.28), b: shank(0.6), ra: r * 0.64, rb: r * 0.52),
                Bone(a: shank(0.6), b: ankle, ra: r * 0.52, rb: r * 0.36),
            ], blend: 0.008 * h)
            let foot = Ellipsoid(center: Vec3(ankle.x, 0.024 * h, 0.04 * h), radii: Vec3(0.027 * h, 0.024 * h, 0.076 * h))
            return (top, knee, ankle, limb, foot)
        }
        let reach = shoulderHalf + armLength * 0.26 + 0.08 * h
        bounds = (Vec3(-reach, -0.01, -0.13 * h), Vec3(reach, h + 0.01, 0.14 * h))
        neckline = (Vec3(0, 1, 0), neckY - 0.004 * h)
        necklineTop = neckY - 0.004 * h
        skinMargin = 0
    }

    // MARK: Distance field

    @inline(__always) func arm(_ i: Int, _ p: Vec3) -> Float {
        smin(arms[i].limb.distance(p), arms[i].hand.distance(p), 0.012 * h)
    }

    @inline(__always) func leg(_ i: Int, _ p: Vec3) -> Float {
        smin(legs[i].limb.distance(p), legs[i].foot.distance(p), 0.014 * h)
    }

    /// Signed distance to the body's skin.
    func distance(_ p: Vec3) -> Float {
        var d = torso.distance(p)
        if p.y > neckY - 0.06 * h {
            d = smin(d, neck.distance(p).d, 0.014 * h)
            d = smin(d, smin(skull.distance(p), jaw.distance(p), 0.03 * h), 0.012 * h)
        }
        if p.y > ankleY + 0.1 * h, p.y < shoulderY + 0.05 * h {
            d = smin(d, arm(0, p), 0.011 * h)
            d = smin(d, arm(1, p), 0.011 * h)
        }
        if p.y < hipY + 0.06 * h {
            d = smin(d, min(leg(0, p), leg(1, p)), 0.012 * h)
        }
        return max(d, -p.y)
    }

    func mesh(cell: Float) -> Mesh {
        if let surface { return surface }
        let (lo, hi) = bounds
        return SurfaceNets.mesh(from: lo, to: hi, cell: cell) { distance($0) }
    }

    var bodyAnchors: [Avatar.Anchor: Vec3] {
        [
            .shoulder: Vec3(shoulderHalf, shoulderY, 0), .chest: Vec3(chest.0, chestY, 0),
            .waist: Vec3(waist.0, waistY, 0), .hip: Vec3(hip.0, hipY, 0),
            .thigh: Vec3(legX + thighR, crotchY - 0.03 * h, 0),
        ]
    }

    /// Value at `y` interpolated through (height, value) keys; flat beyond them.
    func interpolate(_ keys: [(Float, Float)], at y: Float) -> Float {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if y <= first.0 { return first.1 }
        if y >= last.0 { return last.1 }
        for (a, b) in zip(keys, keys.dropFirst()) where y <= b.0 {
            return a.1 + (b.1 - a.1) * (y - a.0) / (b.0 - a.0)
        }
        return last.1
    }

    // MARK: Landmarks

    /// Named body points, on the surface: found by walking out from the bone until past
    /// the skin and, where given, the garment's cut.
    func landmarks(covering cover: ((Vec3) -> Float)?) -> [Avatar.Landmark] {
        let left = arms[0], rightLeg = legs[1], leftLeg = legs[0]
        let specs: [(Avatar.Landmark.Kind, Vec3, Vec3, Float)] = [
            (.neck, Vec3(0, neckY + 0.012 * h, 0), Vec3(-1, 0, 0.3), -1),
            (.shoulder, left.start + Vec3(0, 0.01 * h, 0), Vec3(0.7, 1, 0), 1),
            (.chest, Vec3(-chest.0 * 0.45, chestY, 0), Vec3(0, 0, 1), -1),
            (.elbow, left.start + left.dir * (armLength * 0.55), Vec3(1, 0, -0.3), 1),
            (.waist, Vec3(0, waistY, 0), Vec3(-1, 0, 0), -1),
            (.wrist, left.start + left.dir * armLength, Vec3(1, 0, 0.2), 1),
            (.hip, Vec3(0, hipY, 0), Vec3(1, 0, 0), 1),
            (.crotch, Vec3(0, crotchY + 0.01 * h, 0), Vec3(0, -0.2, 1), -1),
            (.thigh, leftLeg.hip + (leftLeg.knee - leftLeg.hip) * 0.25, Vec3(1, 0, 0.4), 1),
            (.knee, leftLeg.knee, Vec3(0, 0, 1), 1),
            (.ankle, rightLeg.ankle, Vec3(-1, 0, 0.2), -1),
        ]
        return specs.map { kind, inside, direction, side in
            let dir = direction.normalized
            var p = inside
            for _ in 0..<120 {
                let outside = distance(p) > 0 && (cover.map { $0(p) > 0 } ?? true)
                if outside { break }
                p = p + dir * 0.003
            }
            let normal = gradient({ distance($0) }, at: p)
            return Avatar.Landmark(kind: kind, position: p, normal: normal, side: side)
        }
    }
}

// MARK: - Garments

/// The parts a garment is made of: each is an offset of a body part, with its open
/// edges cut by planes (positive outside the garment).
private struct GarmentPart {
    var shape: (Vec3) -> Float
    var planes: [(normal: Vec3, offset: Float)]

    @inline(__always) func clip(_ p: Vec3) -> Float {
        var c = -Float.greatestFiniteMagnitude
        for plane in planes { c = max(c, plane.normal.dot(p) - plane.offset) }
        return c
    }

    @inline(__always) func distance(_ p: Vec3) -> Float { max(shape(p), clip(p)) }
}

extension BodyModel {
    struct Dressed {
        var mesh: Mesh
        var seams: [Vec3]
        var anchors: [Avatar.Anchor: Vec3]
        /// The garment as cut, as a distance field.
        var cut: (Vec3) -> Float
        var report: [FitZone: ZoneReport]
        var frames: [[Vec3]] = []
        var lines: [Avatar.FitLine] = []
    }

    /// Cuts the garment and drapes it. `under` is what's already worn beneath (trousers
    /// under a top), as a distance field the garment rests on as on the body.
    func dress(_ fit: Avatar.GarmentFit, cell: Float, animated: Bool = false, under: ((Vec3) -> Float)? = nil) -> Dressed {
        let fabric = fit.resolvedFabric
        func cm(_ v: Double) -> Float { Float(v / 100) }
        var parts: [GarmentPart] = []
        var lo = Vec3(0, 0, 0), hi = Vec3(0, 0, 0)
        var pinnedAbove: Float = 0
        var anchors: [Avatar.Anchor: Vec3] = [:]
        // Ripples for extra length: along `axis` from `start`, over `length`.
        var stacks: [(part: Int, axis: Vec3, start: Vec3, length: Float)] = []
        // Where loose fabric hangs in vertical folds (how loose, m), and round which axis.
        var hang: (Int, Vec3) -> (amount: Float, axis: Vec3)? = { _, _ in nil }
        let (bodyLo, bodyHi) = bounds
        var shape = GarmentShape(fit: fit, hemY: 0)
        let lift = skinMargin

        switch fit.kind {
        case .trousers:
            let waistband = (waistY + hipY) / 2
            let seatEase = { (y: Float) -> Float in
                self.interpolate([(self.hipY, cm(fit.hipEase)), (waistband, cm(fit.waistEase))], at: y) / (2 * .pi)
            }
            parts.append(GarmentPart(shape: { p in self.torso.distance(p) - seatEase(p.y) - lift },
                                     planes: [(Vec3(0, 1, 0), waistband)]))
            // Longer than the leg: the hem reaches the floor and the rest stacks in folds.
            // Shorter: the hem sits above the ankle.
            let extra = cm(fit.lengthDelta)
            let hemY = extra >= 0 ? max(0.012 * h, ankleY - extra) : ankleY - extra
            let stacked = max(0, extra - (ankleY - 0.012 * h))
            let thighOff = cm(fit.thighEase) / (2 * .pi)
            shape.hemY = hemY
            for (i, leg) in legs.enumerated() {
                var limb = leg.limb
                if hemY < ankleY {
                    limb.bones.append(Bone(a: leg.ankle, b: Vec3(leg.ankle.x, hemY, leg.ankle.z), ra: thighR * 0.36, rb: thighR * 0.36))
                }
                let top = leg.hip.y
                let legEase = { (y: Float) -> Float in
                    let f = min(1, max(0, (top - y) / (top - hemY)))
                    // Full thigh ease at the top, tapering towards the knee and hem.
                    return thighOff * (1 - 0.4 * min(1, f * 1.6)) + 0.006 + 0.003 * f
                }
                // Each leg stays on its own side of the middle: where thighs meet, the two
                // legs of the trousers meet too instead of merging into one tube.
                let side: Float = leg.knee.x > 0 ? 1 : -1
                parts.append(GarmentPart(shape: { p in max(limb.distance(p) - legEase(p.y) - lift, 0.003 - side * p.x) },
                                         planes: [(Vec3(0, -1, 0), -hemY)]))
                if stacked > 0 {
                    stacks.append((i + 1, Vec3(0, 1, 0), Vec3(leg.ankle.x, hemY, 0), min(0.09, stacked * 1.4)))
                }
            }
            hang = { part, _ in
                guard part > 0 else { return nil }
                let leg = self.legs[part - 1]
                return (thighOff - 0.02, Vec3(leg.knee.x, 0, leg.knee.z))
            }
            lo = Vec3(bodyLo.x, max(-0.01, hemY - 0.03), bodyLo.z)
            hi = Vec3(bodyHi.x, waistband + 0.03, bodyHi.z)
            pinnedAbove = waistband - 0.025 * h
            anchors[.hem] = Vec3(legs[0].ankle.x + thighR * 0.4, hemY, 0)
            anchors[.waist] = Vec3(waist.0 + cm(fit.waistEase) / (2 * .pi), waistband, 0)
            anchors[.hip] = Vec3(hip.0 + cm(fit.hipEase) / (2 * .pi), hipY, 0)

        case let .top(longSleeves):
            // A regular top ends just below the hips; longer or shorter moves the hem.
            let hemY = max(0.38 * h, crotchY + 0.035 * h - cm(fit.lengthDelta))
            let dropped = Float(max(0, fit.shoulderDelta) / 200)
            let chestE = cm(fit.chestEase)
            let ease = { (y: Float) -> Float in
                let e = self.interpolate([(self.hipY, cm(max(fit.hipEase, fit.waistEase))), (self.waistY, cm(fit.waistEase)),
                                          (self.chestY, chestE), (self.armpitY, chestE), (self.shoulderY, chestE * 0.5),
                                          (self.neckY, 0.015)], at: y)
                // The yoke rests on the shoulders, always just clear of them. A dropped
                // shoulder moves the seam down the arm (see the stitches and fit lines);
                // the fabric over the shoulder still lies on it.
                let yoke = y >= self.shoulderY - 0.02 * self.h ? max(e, 0.012) : e
                return yoke / (2 * .pi)
            }
            parts.append(GarmentPart(shape: { p in self.torso.distance(p) - ease(p.y) - lift },
                                     planes: [(Vec3(0, -1, 0), -hemY), neckline]))
            // Sleeves start at the shoulder seam: down the arm when the shoulder is dropped.
            let sleeveLength = longSleeves ? armLength + cm(fit.sleeveDelta) : 0.36 * armLength
            let reach = min(sleeveLength, armLength + 0.04 * h)
            let overHand = max(0, sleeveLength - armLength)
            shape.hemY = hemY
            shape.sleeveReach = reach
            shape.longSleeves = longSleeves
            shape.dropped = Float(fit.shoulderDelta / 200)
            let sleeveEase = upperArmR * 0.2 + max(0, chestE / (2 * .pi)) * 0.25
            for (i, arm) in arms.enumerated() {
                var limb = arm.limb
                if reach > armLength {
                    let wrist = arm.start + arm.dir * armLength
                    limb.bones.append(Bone(a: wrist, b: wrist + arm.dir * (reach - armLength), ra: upperArmR * 0.6, rb: upperArmR * 0.6))
                }
                let end = arm.start + arm.dir * reach
                parts.append(GarmentPart(shape: { p in limb.distance(p) - sleeveEase - lift },
                                         planes: [(arm.dir, arm.dir.dot(end))]))
                if overHand > 0, longSleeves {
                    stacks.append((i + 1, arm.dir * -1, end, min(0.07, overHand * 1.5)))
                }
                if anchors[.sleeveEnd] == nil { anchors[.sleeveEnd] = end }
            }
            hang = { part, p in
                guard part == 0, p.y < self.chestY else { return nil }
                return (ease(p.y) - 0.012, Vec3(0, 0, 0))
            }
            let side = shoulderHalf + armLength * max(0.26, abs(arms[0].dir.x)) + 0.06 * h
            lo = Vec3(-side, hemY - 0.03, bodyLo.z)
            hi = Vec3(side, necklineTop + 0.03, bodyHi.z)
            pinnedAbove = shoulderY - 0.02 * h
            anchors[.hem] = Vec3(hip.0 + ease(hemY), hemY, 0)
            anchors[.chest] = Vec3(chest.0 + ease(chestY), chestY, 0)
            anchors[.waist] = Vec3(waist.0 + ease(waistY), waistY, 0)
            anchors[.shoulder] = Vec3(shoulderHalf + dropped, shoulderY, 0)
        }

        let blend = 0.012 * h
        let garmentParts = parts
        // Limbs join the body part smoothly but never each other: trouser legs and
        // sleeves stay separate tubes.
        let cut = { (p: Vec3) -> Float in
            var limbs = Float.greatestFiniteMagnitude
            for part in garmentParts.dropFirst() { limbs = min(limbs, part.distance(p)) }
            return smin(garmentParts[0].distance(p), limbs, blend)
        }
        /// The part that dominates at a point.
        func owner(_ p: Vec3) -> Int {
            var best = 0, bestD = Float.greatestFiniteMagnitude
            for (i, part) in garmentParts.enumerated() {
                let d = part.distance(p)
                if d < bestD { best = i; bestD = d }
            }
            return best
        }

        // The cut surface, opened where the planes close it off.
        let closed = SurfaceNets.mesh(from: lo, to: hi, cell: cell, sdf: cut)
        var keep = [UInt32]()
        for t in stride(from: 0, to: closed.indices.count - 2, by: 3) {
            let a = closed.positions[Int(closed.indices[t])], b = closed.positions[Int(closed.indices[t + 1])]
            let c = closed.positions[Int(closed.indices[t + 2])]
            let centre = (a + b + c) * (1.0 / 3)
            let part = garmentParts[owner(centre)]
            if part.clip(centre) < part.shape(centre) - 0.0015 { keep += closed.indices[t..<(t + 3)] }
        }
        var mesh = Self.compact(closed, keeping: keep)
        // Straighten the open edges onto their cutting plane.
        let neighbours = Self.neighbours(mesh)
        for i in Self.boundaryVertices(mesh) {
            let p = mesh.positions[i]
            let planes = garmentParts[owner(p)].planes
            guard let plane = planes.max(by: { $0.normal.dot(p) - $0.offset < $1.normal.dot(p) - $1.offset }) else { continue }
            // Only onto a plane it's beside: an edge far from every plane is no cut edge.
            let off = plane.normal.dot(p) - plane.offset
            guard abs(off) < 2 * cell else { continue }
            mesh.positions[i] = p - plane.normal * off
        }
        let tags = mesh.positions.map(owner)

        // Drape it.
        var cloth = TriangleCloth(mesh)
        let pinned = mesh.positions.map { $0.y >= pinnedAbove }
        let thickness = fabric.thickness
        let margin = skinMargin
        let rests: (Vec3) -> Float = under.map { inner in { p in min(self.distance(p) - margin, inner(p) - thickness) } }
            ?? { p in self.distance(p) - margin }
        var motion = animated ? TriangleCloth.Motion.dressing : .settle
        if animated {
            switch fit.kind {
            case .top:
                // Sleeves are pulled on up the arm, the body part from above.
                motion.directions = tags.map { $0 > 0 && $0 <= arms.count ? arms[$0 - 1].dir * -1 : Vec3(0, 1, 0) }
            case .trousers:
                // Pulled up from below: started higher, the legs would sit on the wider
                // thigh and stay stretched where friction holds them.
                motion.directions = tags.map { _ in Vec3(0, -1, 0) }
            }
        }
        cloth.drape(body: rests, fabric: fabric, pinned: pinned, motion: motion)
        mesh.positions = cloth.positions
        mesh.strain = fitValues(stretch: cloth.stretch, contact: cloth.contact, fabric: fabric, neighbours: neighbours)
        let report = self.report(cloth, tags: tags, fit: fit, fabric: fabric)
        if case .trousers = fit.kind {
            // A hem resting on the shoe isn't a fit problem; the avatar has no shoes.
            for i in mesh.strain.indices where cloth.rest[i].y < ankleY + 0.015 { mesh.strain[i] = min(mesh.strain[i], 0.5) }
        }
        mesh.computeNormals()

        // Folds: loose fabric hanging in vertical folds, deepening towards the hem (more
        // and deeper for fluid fabrics), and extra length bunched at hems and cuffs.
        for i in mesh.positions.indices where !pinned[i] {
            let p = mesh.positions[i]
            var push: Float = 0
            if let (amount, axis) = hang(tags[i], cloth.rest[i]), amount > 0.004 {
                let top = tags[i] == 0 ? chestY : crotchY
                let ramp = min(1, max(0, (top - p.y) / max(0.1, top - lo.y)))
                let theta = atan2(p.z - axis.z, p.x - axis.x)
                let wave = 0.5 * (1 + cos(Float(fabric.folds) * theta))
                push += min(0.012, amount * 0.5) * (1.25 - fabric.drape) * ramp * wave
            }
            for stack in stacks where stack.part == tags[i] {
                let along = (p - stack.start).dot(stack.axis)
                guard along >= 0, along <= stack.length else { continue }
                push += 0.007 * 0.5 * (1 + cos(along / 0.018 * 2 * .pi)) * (1 - along / stack.length * 0.5)
            }
            if push > 0 { mesh.positions[i] = mesh.positions[i] + mesh.normals[i] * push }
        }
        mesh.computeNormals()

        // The animation ends on the finished garment: the fold detail added after the
        // simulation fades in over its frames.
        var frames = cloth.frames
        if frames.count > 1 {
            let simulated = cloth.positions
            for (k, frame) in frames.enumerated() {
                let f = Float(k) / Float(frames.count - 1)
                let blend = f * f
                frames[k] = frame.indices.map { i in frame[i] + (mesh.positions[i] - simulated[i]) * blend }
            }
        }

        (mesh.tones, mesh.toneWeight) = tones(shape, rest: cloth.rest, tags: tags, stretch: cloth.stretch,
                                              contact: cloth.contact, gap: cloth.gap, fabric: fabric,
                                              neighbours: neighbours)
        mesh.sway = sway(shape, rest: cloth.rest, tags: tags, gap: cloth.gap, pinnedAbove: pinnedAbove, fabric: fabric)
        let cover: (Vec3) -> Float = under.map { inner in { p in min(cut(p), inner(p)) } } ?? cut
        let lines = fitLines(shape, mesh: mesh, tags: tags, cover: cover, report: report)
        let seams = stitches(fit, mesh: mesh, tags: tags)
        if case .trousers = fit.kind, let lowest = mesh.positions.filter({ $0.x > 0 }).min(by: { $0.y < $1.y }) {
            anchors[.hem] = Vec3(anchors[.hem]?.x ?? lowest.x, lowest.y, 0)
        }
        return Dressed(mesh: mesh, seams: seams, anchors: anchors, cut: cut, report: report, frames: frames, lines: lines)
    }

    /// Stitch lines where the garment has them, as dash segments slightly off the
    /// fabric: each is where a function over the surface crosses zero, kept on the
    /// vertices of the given parts, dashed every 8 mm along `dash`.
    private func stitches(_ fit: Avatar.GarmentFit, mesh: Mesh, tags: [Int]) -> [Vec3] {
        typealias Line = (f: (Vec3) -> Float, parts: Set<Int>, dash: (Vec3) -> Float)
        var lines: [Line] = []
        let byHeight = { (p: Vec3) -> Float in p.y }
        func around(_ axis: Vec3) -> (Vec3) -> Float { { p in atan2(p.z - axis.z, p.x - axis.x) * 0.12 } }
        let mid = { (y: Float) -> Float in self.torso.ring(at: y).center.z }
        switch fit.kind {
        case .trousers:
            let waistband = (waistY + hipY) / 2
            let hems = mesh.positions.map(\.y).min() ?? 0
            lines.append(({ $0.y - (waistband - 0.035) }, [0], around(Vec3(0, 0, 0))))
            lines.append(({ $0.y - (waistband - 0.006) }, [0], around(Vec3(0, 0, 0))))
            // Front and back rise down the middle.
            lines.append(({ $0.x }, [0], byHeight))
            for (i, leg) in legs.enumerated() {
                let axis = Vec3(leg.knee.x, 0, leg.knee.z)
                lines.append(({ $0.y - (hems + 0.018) }, [i + 1], around(axis)))
                // Outside and inside leg seams.
                lines.append(({ $0.z - axis.z }, [i + 1], byHeight))
            }
        case .top:
            // The body part's lowest edge (long sleeves can hang lower).
            let hem = mesh.positions.indices.filter { tags[$0] == 0 }.map { mesh.positions[$0].y }.min() ?? 0
            let neck = neckline
            lines.append(({ $0.y - (hem + 0.014) }, [0], around(Vec3(0, 0, 0))))
            lines.append(({ $0.dot(neck.normal) - (neck.offset - 0.01) }, [0], around(Vec3(0, 0, 0))))
            // Side seams below the arms, shoulder seams over the top.
            let armpit = armpitY - 0.01 * h, yoke = shoulderY - 0.015 * h
            lines.append(({ p in p.y < armpit && abs(p.x) > 0.05 ? p.z - mid(p.y) : .nan }, [0], byHeight))
            lines.append(({ p in p.y > yoke && abs(p.x) > 0.06 ? p.z - mid(p.y) : .nan }, [0], { $0.x }))
            let dropped = Float(fit.shoulderDelta / 200)
            for (i, arm) in arms.enumerated() {
                var end: Float = -1
                for v in mesh.positions.indices where tags[v] == i + 1 { end = max(end, mesh.positions[v].dot(arm.dir)) }
                let dir = arm.dir
                let pit = armpitY - 0.02 * h
                lines.append(({ p in p.y > pit ? self.armhole(i, p) - dropped : .nan }, [0, i + 1], { $0.y + $0.z }))
                lines.append(({ $0.dot(dir) - (end - 0.014) }, [i + 1], { $0.z + $0.y * 0.3 }))
            }
        }
        return lines.flatMap { contour($0.f, parts: $0.parts, mesh: mesh, tags: tags, dash: $0.dash) }
    }

    /// The mesh with only the given triangles, unused vertices dropped.
    static func compact(_ mesh: Mesh, keeping indices: [UInt32]) -> Mesh {
        var map = [Int32](repeating: -1, count: mesh.positions.count)
        var out = Mesh()
        for i in indices {
            if map[Int(i)] < 0 {
                map[Int(i)] = Int32(out.positions.count)
                out.positions.append(mesh.positions[Int(i)])
                out.normals.append(mesh.normals[Int(i)])
            }
            out.indices.append(UInt32(map[Int(i)]))
        }
        return out
    }

    static func neighbours(_ mesh: Mesh) -> [[Int]] {
        var n = [Set<Int>](repeating: [], count: mesh.positions.count)
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            for e in 0..<3 {
                let a = Int(mesh.indices[t + e]), b = Int(mesh.indices[t + (e + 1) % 3])
                n[a].insert(b); n[b].insert(a)
            }
        }
        return n.map { Array($0) }
    }

    /// Vertices on an edge only one triangle uses.
    static func boundaryVertices(_ mesh: Mesh) -> Set<Int> {
        var count: [Int: Int] = [:]
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            for e in 0..<3 {
                let a = Int(mesh.indices[t + e]), b = Int(mesh.indices[t + (e + 1) % 3])
                count[min(a, b) << 32 | max(a, b), default: 0] += 1
            }
        }
        var out = Set<Int>()
        for (key, c) in count where c == 1 { out.insert(key >> 32); out.insert(key & 0xFFFF_FFFF) }
        return out
    }
}
