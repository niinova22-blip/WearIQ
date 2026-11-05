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
        /// Where its hem, legs and sleeves end on the body.
        public var placements: [Placement] = []
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
        /// Shapes the bust; nil is a body between the two.
        public var sex: BodySex?
        /// Under the breasts (from a bra size): the bust is then the chest minus this,
        /// instead of the usual one for the sex.
        public var underbust: Double?
        /// The shape fitted to the scan's silhouettes, when there is one.
        public var shape: [Double]?

        public init(height: Double, chest: Double, waist: Double, hip: Double, thigh: Double,
                    shoulderWidth: Double, armLength: Double, inseam: Double, sex: BodySex? = nil) {
            self.height = height; self.chest = chest; self.waist = waist; self.hip = hip; self.thigh = thigh
            self.shoulderWidth = shoulderWidth; self.armLength = armLength; self.inseam = inseam
            self.sex = sex
        }

        /// From a body profile; missing values fall back to typical stature fractions.
        public init?(_ p: BodyProfile) {
            guard let h = p[.height]?.cm else { return nil }
            self.init(height: h, chest: p[.chest]?.cm ?? 0.55 * h, waist: p[.waist]?.cm ?? 0.48 * h,
                      hip: p[.hip]?.cm ?? 0.55 * h, thigh: p[.thigh]?.cm ?? 0.32 * h,
                      shoulderWidth: p[.shoulderWidth]?.cm ?? 0.23 * h, armLength: p[.armLength]?.cm ?? 0.34 * h,
                      inseam: p[.inseam]?.cm ?? 0.47 * h, sex: p.sex)
            underbust = p.underbustCm
            shape = p.shapeCoefficients
        }

        /// How far the bust stands out (chest minus underbust, on the shape model's own
        /// measure): from the bra size when given (an A cup is about 12 cm, each cup 2–2.5 cm
        /// more), otherwise the usual one for the sex; nil without either.
        public var bust: Double? {
            if let underbust, underbust > 0 { return min(26, max(6, chest - underbust)) }
            return sex.map { SomaModel.typicalBust(female: $0 == .female, chest: chest) }
        }
    }

    /// How a garment sits, in cm: girth ease is garment minus body circumference; the
    /// deltas are how much longer (+) or shorter (−) than the body the garment is.
    public struct GarmentFit: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case top(longSleeves: Bool)
            case trousers
            /// From the waist down over both legs, with no legs of its own.
            case skirt

            /// Worn from the waist down, under a top.
            public var isBottom: Bool {
                switch self {
                case .trousers, .skirt: true
                case .top: false
                }
            }
        }

        /// What kind of top, where it differs from a plain T-shirt or shirt: a jacket or
        /// coat is a heavier woven, open down the front, with lapels; a coat and a dress
        /// hang on past the hips over both legs, flaring out a little.
        public enum Style: Equatable, Sendable {
            case plain, jacket, coat, dress

            var isOuter: Bool { self == .jacket || self == .coat }
        }

        public var kind: Kind
        public var style: Style = .plain
        /// The cut the garment is made in: an oversized top is roomy by design, so its
        /// room only counts as loose past what the cut has (`looseEase`).
        public var cut: FitStyle = .regular
        /// Trousers: how the legs are cut from the knee down (skinny to the ankle, straight
        /// from the knee, wide…). Nil: a regular leg, tapering a little to the hem.
        public var legCut: LegCut?
        /// How much wider the garment gets below the hips, metres of radius per metre
        /// down: 0 straight, about 0.1 for a coat, 0.15–0.3 for an A-line skirt or dress.
        /// Nil takes the style's usual one.
        public var flare: Double?
        /// Whether the length and sleeve came from the size chart (otherwise they are the
        /// usual ones for the kind and size, and said to be estimates).
        public var lengthFromChart = true
        /// How much longer (+) or shorter than the usual length for its kind the garment is
        /// cut by design, cm: a mini skirt, a maxi dress, a long coat. Moves the hem
        /// without making it "too long" or "too short".
        public var hemOffset: Double = 0
        public var sleeveFromChart = true
        public var chestEase: Double = 10
        public var waistEase: Double = 8
        public var hipEase: Double = 8
        public var thighEase: Double = 6
        public var lengthDelta: Double = 0
        public var sleeveDelta: Double = 0
        public var shoulderDelta: Double = 0
        /// The fabric; without one, tops drape as a plain knit and trousers as a woven.
        public var fabric: Fabric?
        /// Sewn from flat pattern pieces (`BodyModel.panels`) and draped for real. Off:
        /// the older moulded shell, kept for comparison.
        public var sewn = true

        /// Drapes from flat pieces: garments that follow the body (a regular tee or shirt,
        /// close-cut trousers). Cuts whose silhouette is the design (straight, wide and
        /// flared legs, oversized tops, coats, jackets, dresses, skirts) keep the shape
        /// they are cut in, as their stiffer fabric and shaped pattern keep it on a person:
        /// draped from flat, a wide leg fell straight and an oversized tee sagged at the
        /// neck (RenderProbe/cuts).
        var drapesFromFlat: Bool {
            guard sewn else { return false }
            switch kind {
            case .skirt: return false
            case .trousers: return ![LegCut.straight, .wide, .flare].contains(legCut ?? .slim)
            // As much room as an oversized cut is its silhouette too, whatever the label.
            case .top: return style == .plain && cut != .oversized && chestEase < 20
            }
        }
        /// What the size-chart check concluded, where it concluded something. The drape
        /// keeps the garment's real dimensions; the colours, lines and labels say what
        /// this says, so the avatar and the verdicts beside it never disagree.
        public var judged = Judged()

        /// Verdicts from the size-chart check. Lengths are how far beyond the usual
        /// range the garment is, cm (+ long, − short, 0 within it); the shoulder is how
        /// far each seam sits from the shoulder point (+ down the arm, − inside it).
        public struct Judged: Equatable, Sendable {
            public var length: Double?
            public var sleeve: Double?
            public var shoulderPerSide: Double?
            public var waist: FitTone?
            /// Per zone, how the size chart says it sits: loose, fits or tight. A zone with
            /// a verdict is coloured as the verdict says (tight where the fabric touches,
            /// loose over the zone), and the zone report gives `tensions` for it.
            public var zones: [FitZone: FitTone]
            /// The same verdicts in the zone report's words (slightly tight, tight…).
            public var tensions: [FitZone: ZoneTension]

            public init(length: Double? = nil, sleeve: Double? = nil, shoulderPerSide: Double? = nil, waist: FitTone? = nil,
                        zones: [FitZone: FitTone] = [:], tensions: [FitZone: ZoneTension] = [:]) {
                self.length = length
                self.sleeve = sleeve
                self.shoulderPerSide = shoulderPerSide
                self.waist = waist
                self.zones = zones
                self.tensions = tensions
            }
        }

        public init(kind: Kind) { self.kind = kind }

        /// The length to colour and label by, and how far past "usual" it must be to count.
        var shownLength: (delta: Double, threshold: Double) {
            if let j = judged.length { return (j, 0.5) }
            if case .trousers = kind { return (lengthDelta, 1.5) }
            return (lengthDelta, 2)
        }

        /// Radius added per metre below the hips.
        var resolvedFlare: Float {
            if let flare { return Float(max(0, flare)) }
            switch (kind, style) {
            case (.skirt, _): return 0.12
            case (.top, .dress): return 0.16
            case (.top, .coat): return 0.08
            default: return 0
            }
        }

        var shownSleeve: (delta: Double, threshold: Double) {
            judged.sleeve.map { ($0, 0.5) } ?? (sleeveDelta, 1.5)
        }

        /// Without a verdict, a seam dropped as far as the cut drops it (an oversized top
        /// up to about 6 cm a side, a relaxed one 2) is where it belongs.
        var shownShoulderPerSide: (delta: Double, threshold: Double) {
            if let judged = judged.shoulderPerSide { return (judged, 0.5) }
            let designed: Double = cut == .oversized ? 6 : cut == .relaxed ? 2 : 0
            let d = shoulderDelta / 2
            return (d > 0 ? max(0, d - designed) : d, 1)
        }

        var resolvedFabric: Fabric {
            if let fabric { return fabric }
            if kind.isBottom { return .woven }
            if style.isOuter { return .outerwear }
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
            func inner(_ i: Int) -> Int { garments[i].kind.isBottom ? 0 : 1 }
            return inner(a) < inner(b)
        }
        // Each garment rests on the cut shells of those beneath it, which don't depend
        // on how those drape, so all of them are draped at once, each on its own core.
        let patterns = garments.map(model.pattern)
        var cover: ((Vec3) -> Float)?
        var under: [Int: (Vec3) -> Float] = [:]
        for i in order {
            if let cover { under[i] = cover }
            let shell = model.shell(patterns[i])
            cover = cover.map { previous in { p in min(previous(p), shell(p)) } } ?? shell
        }
        let results = DressingResults(count: garments.count)
        // The patterns' closures only read the body model and their own cut values.
        let inputs = Unchecked((patterns, under))
        DispatchQueue.concurrentPerform(iterations: garments.count) { i in
            let (patterns, under) = inputs.value
            results.set(i, model.dress(patterns[i], cell: detail.garment, animated: detail.animated, under: under[i]))
        }
        var dressed: [Int: BodyModel.Dressed] = [:]
        for i in garments.indices { dressed[i] = results.value(i) }
        for i in garments.indices.reversed() {
            guard let d = dressed[i] else { continue }
            anchors.merge(d.anchors) { _, new in new }
        }
        layers = garments.indices.compactMap { i in
            dressed[i].map { Layer(fit: garments[i], mesh: $0.mesh, frames: $0.frames, seams: $0.seams,
                                   fitLines: $0.lines, placements: $0.placements, fitReport: $0.report) }
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

/// Hands values made of pure closures to the threads that drape garments side by side.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Garments draped side by side write their results here, each to its own slot.
private final class DressingResults: @unchecked Sendable {
    private var slots: [BodyModel.Dressed?]
    private let lock = NSLock()
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ value: BodyModel.Dressed) { lock.lock(); slots[i] = value; lock.unlock() }
    func value(_ i: Int) -> BodyModel.Dressed? { lock.lock(); defer { lock.unlock() }; return slots[i] }
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
        /// The space the draped garment takes up, as a distance field: its cut, and
        /// wherever it covers the body at least the skin plus the fabric (a garment cut
        /// smaller than the body is stretched out over it). What goes on over it rests
        /// on this.
        var cut: (Vec3) -> Float
        var report: [FitZone: ZoneReport]
        var frames: [[Vec3]] = []
        var lines: [Avatar.FitLine] = []
        var placements: [Avatar.Placement] = []
    }

    /// Cuts the garment and drapes it. `under` is what's already worn beneath (trousers
    /// under a top), as a distance field the garment rests on as on the body.
    func dress(_ fit: Avatar.GarmentFit, cell: Float, animated: Bool = false, under: ((Vec3) -> Float)? = nil) -> Dressed {
        dress(pattern(fit), cell: cell, animated: animated, under: under)
    }

    /// The garment as cut, before it is draped: its parts, the box it is meshed in, where
    /// it hangs from and how its looseness is laid out. What goes over it rests on its
    /// `shell`, which needs only this, so garments worn together can drape at once.
    struct Pattern {
        var fit: Avatar.GarmentFit
        var fabric: Fabric
        fileprivate var parts: [GarmentPart]
        var lo: Vec3, hi: Vec3
        var pinnedAbove: Float
        var anchors: [Avatar.Anchor: Vec3]
        var stacks: [(part: Int, axis: Vec3, start: Vec3, length: Float)]
        var hang: (Int, Vec3) -> (amount: Float, axis: Vec3)?
        var cutEase: (Int, Float) -> Float
        var shape: GarmentShape
    }

    func pattern(_ fit: Avatar.GarmentFit) -> Pattern {
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
        // The girth ease the garment is cut with, cm, by part and height (as cut).
        var cutEase: (Int, Float) -> Float = { _, _ in 0 }
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
            // Shorts are trousers cut short by design (`hemOffset`), not "too short".
            let extra = cm(fit.lengthDelta + fit.hemOffset)
            let hemY = extra >= 0 ? max(0.012 * h, ankleY - extra) : min(crotchY - 0.04 * h, ankleY - extra)
            let stacked = max(0, extra - (ankleY - 0.012 * h))
            let thighOff = cm(fit.thighEase) / (2 * .pi)
            shape.hemY = hemY
            // How the leg is cut from the knee down. Skinny, slim and tapered legs follow
            // the leg, closer or roomier (an offset of the leg's own shape, calf and all);
            // straight, wide and flared legs hang as a tube of their own from the seat to
            // the hem, whatever the calf and ankle do inside it. Either way the thigh keeps
            // the size chart's room; below the knee the room is the cut's, a little more
            // for a bigger size of it.
            let legCut = fit.legCut
            let taper: (shape: Float, knee: Float, hem: Float)
            switch legCut {
            case .skinny?: taper = (0.85, 0.003, 0.001)
            case .slim?: taper = (0.6, 0.005, 0.004)
            case .tapered?: taper = (0.8, 0.012, -0.01)
            // A flare is close down to the knee; its tube opens it below.
            case .flare?: taper = (0.8, 0.004, 0.002)
            default: taper = (0.4, 0.006, 0.003)
            }
            // Girth ease at the knee and how much wider (+) the hem opening is than that,
            // cm, for the cuts that hang free of the leg; and the thigh ease the cut's
            // usual size has, to grade the rest with the size.
            let tubeCut: (knee: Double, hemOverKnee: Double, usualThigh: Double)? = switch legCut {
            case .straight?: (9, 0, 9)
            case .wide?: (18, 8, 18)
            case .flare?: (2, 15, 5)
            default: nil
            }
            var hemRadius: [Float] = []
            for (i, leg) in legs.enumerated() {
                var limb = leg.limb
                if hemY < ankleY {
                    limb.bones.append(Bone(a: leg.ankle, b: Vec3(leg.ankle.x, hemY, leg.ankle.z), ra: thighR * 0.36, rb: thighR * 0.36))
                }
                let top = leg.hip.y
                let legEase = { (y: Float) -> Float in
                    let f = min(1, max(0, (top - y) / (top - hemY)))
                    // Full thigh ease at the top, tapering towards the knee and hem.
                    return thighOff * (1 - taper.shape * min(1, f * 1.6)) + taper.knee + taper.hem * f
                }
                var tube: Limb?
                if let cut = tubeCut {
                    let grade = min(6, max(-4, (fit.thighEase - cut.usualThigh) * 0.5))
                    let kneeBody = max(0.03, -leg.limb.distance(leg.knee))
                    let kneeR = kneeBody + cm(cut.knee + grade) / (2 * .pi)
                    let hemR = max(kneeR * 0.75, kneeR + cm(cut.hemOverKnee) / (2 * .pi))
                    let down = (leg.ankle - leg.knee).normalized
                    let reach = (leg.knee.y - hemY) / max(0.2, -down.y)
                    let hem = leg.knee + down * reach
                    // From the seat, as wide as the chart's thigh there, to the knee and hem.
                    // Started a little below the groin, so its rounded end stays inside the seat.
                    let start = leg.hip + (leg.knee - leg.hip) * 0.15
                    let topR = thighR * 0.95 + thighOff * 0.9
                    tube = Limb(bones: [Bone(a: start, b: leg.knee, ra: topR, rb: kneeR),
                                        Bone(a: leg.knee, b: hem, ra: kneeR, rb: hemR)], blend: 0.02)
                    hemRadius.append(hemR - max(0.02, -leg.limb.distance(leg.ankle)))
                }
                // Each leg stays on its own side of the middle: where thighs meet, the two
                // legs of the trousers meet too instead of merging into one tube.
                let side: Float = leg.knee.x > 0 ? 1 : -1
                let free = tube
                parts.append(GarmentPart(shape: { p in
                    var d = limb.distance(p) - legEase(p.y)
                    if let free { d = min(d, free.distance(p)) }
                    return max(d - lift, 0.003 - side * p.x)
                }, planes: [(Vec3(0, -1, 0), -hemY)]))
                if stacked > 0 {
                    stacks.append((i + 1, Vec3(0, 1, 0), Vec3(leg.ankle.x, hemY, 0), min(0.09, stacked * 1.4)))
                }
            }
            // A free-hanging leg folds as much as it has room round the ankle.
            let freeRoom = hemRadius.max() ?? 0
            hang = { part, _ in
                guard part > 0 else { return nil }
                let leg = self.legs[part - 1]
                return (max(thighOff - 0.02, freeRoom * 0.5), Vec3(leg.knee.x, 0, leg.knee.z))
            }
            cutEase = { part, y in
                if part == 0 {
                    return self.interpolate([(self.hipY, Float(fit.hipEase)), (waistband, Float(fit.waistEase))], at: y)
                }
                // The thigh's ease, narrowing towards the knee as the leg is cut.
                let top = self.legs[part - 1].hip.y
                let f = min(1, max(0, (top - y) / (top - hemY)))
                return Float(fit.thighEase) * (1 - 0.4 * min(1, f * 1.6))
            }
            // The box the cut is meshed in reaches past the body by the garment's room:
            // fabric outside it would be cut away, leaving a hole (loose trousers opened
            // at the back, where the seat stands out furthest).
            let pad = max(0, cm(max(fit.hipEase, fit.waistEase, fit.thighEase))) / (2 * .pi) + lift + 0.03 + freeRoom
            lo = Vec3(bodyLo.x - pad, max(-0.01, hemY - 0.03), bodyLo.z - pad)
            hi = Vec3(bodyHi.x + pad, waistband + 0.03, bodyHi.z + pad)
            pinnedAbove = waistband - 0.025 * h
            anchors[.hem] = Vec3(legs[0].ankle.x + thighR * 0.4 + freeRoom, hemY, 0)
            anchors[.waist] = Vec3(waist.0 + cm(fit.waistEase) / (2 * .pi), waistband, 0)
            anchors[.hip] = Vec3(hip.0 + cm(fit.hipEase) / (2 * .pi), hipY, 0)

        case .skirt:
            // From the waistband over the seat, then on down round both legs together.
            let waistband = (waistY + hipY) / 2
            let hemY = max(0.05 * h, regularHem(fit) - cm(fit.lengthDelta))
            let seat = { (y: Float) -> Float in
                self.interpolate([(self.hipY, cm(fit.hipEase)), (waistband, cm(fit.waistEase))], at: y) / (2 * .pi)
            }
            let flare = fit.resolvedFlare
            let tube = self.tube(ease: cm(fit.hipEase) / (2 * .pi), flare: flare)
            parts.append(GarmentPart(shape: { p in
                min(self.torso.distance(p) - seat(p.y), tube(p)) - lift
            }, planes: [(Vec3(0, 1, 0), waistband), (Vec3(0, -1, 0), -hemY)]))
            shape.hemY = hemY
            let middle = torso.ring(at: hipY).center
            hang = { _, p in
                guard p.y < self.hipY else { return nil }
                return (cm(fit.hipEase) / (2 * .pi) + flare * (self.hipY - p.y), Vec3(middle.x, 0, middle.z))
            }
            cutEase = { _, y in
                let base = self.interpolate([(self.hipY, Float(fit.hipEase)), (waistband, Float(fit.waistEase))], at: y)
                // The flare is the style, not room for the body: not counted.
                return base
            }
            let reach = max(0, cm(fit.hipEase) / (2 * .pi)) + flare * max(0, hipY - hemY)
            let pad = reach + lift + 0.04
            lo = Vec3(bodyLo.x - pad, max(-0.01, hemY - 0.03), bodyLo.z - pad)
            hi = Vec3(bodyHi.x + pad, waistband + 0.03, bodyHi.z + pad)
            pinnedAbove = waistband - 0.025 * h
            anchors[.hem] = Vec3(hip.0 + reach, hemY, 0)
            anchors[.waist] = Vec3(waist.0 + cm(fit.waistEase) / (2 * .pi), waistband, 0)
            anchors[.hip] = Vec3(hip.0 + cm(fit.hipEase) / (2 * .pi), hipY, 0)

        case let .top(longSleeves):
            // A regular top ends just below the hips (a coat above the knee, a dress at
            // it); longer or shorter moves the hem.
            let long = fit.style == .coat || fit.style == .dress
            let hemY = max(long ? 0.06 * h : 0.38 * h, regularHem(fit) - cm(fit.lengthDelta))
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
            // Past the hips a long top hangs round both legs together, as a skirt does.
            let flare = fit.resolvedFlare
            let below: ((Vec3) -> Float)? = hemY < crotchY + 0.02 * h
                ? tube(ease: cm(max(fit.hipEase, fit.waistEase)) / (2 * .pi), flare: flare) : nil
            parts.append(GarmentPart(shape: { p in
                let body = self.torso.distance(p) - ease(p.y)
                return (below.map { min(body, $0(p)) } ?? body) - lift
            }, planes: [(Vec3(0, -1, 0), -hemY), neckline]))
            // Sleeves start at the shoulder seam: down the arm when the shoulder is dropped.
            let sleeveLength = longSleeves ? armLength + cm(fit.sleeveDelta) : 0.36 * armLength
            let reach = min(sleeveLength, armLength + 0.04 * h)
            let overHand = max(0, sleeveLength - armLength)
            shape.hemY = hemY
            shape.sleeveReach = reach
            shape.longSleeves = longSleeves
            shape.dropped = Float(fit.shoulderDelta / 200)
            // Room round the arm: most at the armhole, tapering to the cuff as a sleeve is
            // cut (a loose top's sleeves used to stay as wide as the armhole down to the
            // wrist and flared like bells). A jacket's sleeve is roomier, to go over another.
            let sleeveTop = upperArmR * (fit.style.isOuter ? 0.45 : 0.2) + max(0, chestE / (2 * .pi)) * 0.25
            let sleeveCuff = min(sleeveTop, max(sleeveTop * 0.6, upperArmR * (fit.style.isOuter ? 0.6 : 0.3) + 0.004))
            for (i, arm) in arms.enumerated() {
                var limb = arm.limb
                if reach > armLength {
                    let wrist = arm.start + arm.dir * armLength
                    limb.bones.append(Bone(a: wrist, b: wrist + arm.dir * (reach - armLength), ra: upperArmR * 0.55, rb: upperArmR * 0.55))
                }
                let end = arm.start + arm.dir * reach
                let start = arm.start, dir = arm.dir
                parts.append(GarmentPart(shape: { p in
                    let f = min(1, max(0, (p - start).dot(dir) / reach))
                    return limb.distance(p) - (sleeveTop + (sleeveCuff - sleeveTop) * f) - lift
                }, planes: [(arm.dir, arm.dir.dot(end))]))
                if overHand > 0, longSleeves {
                    stacks.append((i + 1, arm.dir * -1, end, min(0.07, overHand * 1.5)))
                }
                if anchors[.sleeveEnd] == nil { anchors[.sleeveEnd] = end }
            }
            hang = { part, p in
                guard part == 0, p.y < self.chestY else { return nil }
                return (ease(p.y) - 0.012 + flare * max(0, self.hipY - p.y), Vec3(0, 0, 0))
            }
            cutEase = { part, y in
                guard part == 0 else { return 0 }
                return self.interpolate([(self.hipY, Float(max(fit.hipEase, fit.waistEase))), (self.waistY, Float(fit.waistEase)),
                                         (self.chestY, Float(fit.chestEase)), (self.armpitY, Float(fit.chestEase))], at: y)
            }
            let side = shoulderHalf + armLength * max(0.26, abs(arms[0].dir.x)) + 0.06 * h
            // Past the body by the garment's room, as for trousers.
            let pad = max(0, cm(max(fit.chestEase, fit.waistEase, fit.hipEase))) / (2 * .pi) + lift + 0.03
                + flare * max(0, hipY - hemY)
            lo = Vec3(-side, max(-0.01, hemY - 0.03), bodyLo.z - pad)
            hi = Vec3(side, necklineTop + 0.03, bodyHi.z + pad)
            pinnedAbove = shoulderY - 0.02 * h
            anchors[.hem] = Vec3(hip.0 + ease(hemY), hemY, 0)
            anchors[.chest] = Vec3(chest.0 + ease(chestY), chestY, 0)
            anchors[.waist] = Vec3(waist.0 + ease(waistY), waistY, 0)
            anchors[.shoulder] = Vec3(shoulderHalf + dropped, shoulderY, 0)
        }

        return Pattern(fit: fit, fabric: fabric, parts: parts, lo: lo, hi: hi, pinnedAbove: pinnedAbove, anchors: anchors,
                       stacks: stacks, hang: hang, cutEase: cutEase, shape: shape)
    }

    /// The cut garment's surface, smoothly joined: limbs join the body part but never
    /// each other, so trouser legs and sleeves stay separate tubes.
    func cutField(_ pattern: Pattern) -> (Vec3) -> Float {
        let blend = 0.012 * h
        let garmentParts = pattern.parts
        return { (p: Vec3) -> Float in
            var limbs = Float.greatestFiniteMagnitude
            for part in garmentParts.dropFirst() { limbs = min(limbs, part.distance(p)) }
            return smin(garmentParts[0].distance(p), limbs, blend)
        }
    }

    /// What goes on over the garment rests on: over its height, the skin it covers plus
    /// the margin and the fabric, or the cut where that stands further out. The gap keeps
    /// whatever goes over it from resting in the same place.
    func shell(_ pattern: Pattern) -> (Vec3) -> Float {
        let cut = cutField(pattern)
        let margin = skinMargin, thickness = pattern.fabric.thickness
        let top: Float = pattern.fit.kind.isBottom ? (waistY + hipY) / 2 : necklineTop
        let bottom = pattern.shape.hemY
        return { (p: Vec3) -> Float in
            min(cut(p), max(self.distance(p) - margin - thickness - 0.002, p.y - top, bottom - p.y))
        }
    }

    func dress(_ pattern: Pattern, cell: Float, animated: Bool = false, under: ((Vec3) -> Float)? = nil) -> Dressed {
        let fit = pattern.fit, fabric = pattern.fabric
        let parts = pattern.parts, lo = pattern.lo, hi = pattern.hi, pinnedAbove = pattern.pinnedAbove
        var anchors = pattern.anchors
        let stacks = pattern.stacks, hang = pattern.hang, cutEase = pattern.cutEase, shape = pattern.shape
        let garmentParts = parts
        let cut = cutField(pattern)
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
            guard var plane = planes.max(by: { $0.normal.dot(p) - $0.offset < $1.normal.dot(p) - $1.offset }) else { continue }
            var off = plane.normal.dot(p) - plane.offset
            if abs(off) >= 2 * cell {
                // An edge vertex the neighbouring part owns (a trouser leg's, up at the
                // back of the waistband): the nearest of any part's cutting planes.
                let all = garmentParts.flatMap(\.planes)
                if let near = all.min(by: { abs($0.normal.dot(p) - $0.offset) < abs($1.normal.dot(p) - $1.offset) }) {
                    plane = near
                    off = near.normal.dot(p) - near.offset
                }
            }
            // Only onto a plane it's beside: an edge far from every plane is no cut edge.
            guard abs(off) < 2 * cell else { continue }
            mesh.positions[i] = p - plane.normal * off
        }
        let tags = mesh.positions.map(owner)

        // Drape it, sewn from its pattern pieces.
        var cloth = TriangleCloth(mesh, panels: fit.drapesFromFlat ? panels(fit, mesh: mesh, owner: owner) : nil)
        let pinned = mesh.positions.map { $0.y >= pinnedAbove }
        let thickness = fabric.thickness
        let margin = skinMargin
        let rests: (Vec3) -> Float = under.map { inner in { p in min(self.distance(p) - margin, inner(p) - thickness) } }
            ?? { p in self.distance(p) - margin }
        var motion = animated ? TriangleCloth.Motion.dressing : .settle
        // A sewn garment settles for real: long enough for its weight to drape it.
        if fit.drapesFromFlat && !animated {
            // 72 steps of 1/60 s: as good as twice as many (RenderProbe), the extra time
            // a fraction of a second.
            motion.steps = 72
            motion.damping = 0.9
        }
        if animated {
            switch fit.kind {
            case .top:
                // Sleeves are pulled on up the arm, the body part from above.
                motion.directions = tags.map { $0 > 0 && $0 <= arms.count ? arms[$0 - 1].dir * -1 : Vec3(0, 1, 0) }
            case .trousers, .skirt:
                // Pulled up from below: started higher, the legs would sit on the wider
                // thigh and stay stretched where friction holds them.
                motion.directions = tags.map { _ in Vec3(0, -1, 0) }
            }
        }
        cloth.axes = tags.map { tag in
            if case .top = fit.kind, tag > 0, tag <= arms.count { return arms[tag - 1].dir }
            return Vec3(0, 1, 0)
        }
        // The solver's many queries go to a sampled copy of the field (see SampledField),
        // over the box the garment can move in; what it reports as contact at the end is
        // measured on the exact field.
        let reach = Vec3(0.1, 0.1 + motion.lift, 0.1)
        let sampled = SampledField(rests, from: lo - reach, to: hi + reach)
        cloth.drape(body: { sampled($0) }, exact: rests, fabric: fabric, pinned: pinned, motion: motion)
        mesh.positions = cloth.positions
        // The skin shown is finer than the field the cloth collided with: wherever the
        // cloth ended inside it or right on it (the small of the back under loose
        // trousers), it goes back out, so no skin shows through fabric.
        liftOffSkin(&mesh.positions, clearance: max(0.003, thickness + 0.002))
        // The solver's grid buckles in creases one cell wide, which read as crumpled paper
        // and as a ragged hem; real cloth's bending stiffness doesn't make them. They're
        // smoothed away, the folds wider than a few cells kept, and the fabric put back
        // off the skin.
        Self.smoothCloth(&mesh.positions, neighbours: neighbours, boundary: Self.boundaryVertices(mesh), pinned: pinned)
        liftOffSkin(&mesh.positions, clearance: max(0.003, thickness + 0.002))
        // Tightness is the body pressing on the fabric. Over another garment, a top
        // stretched round the trousers' loose fabric isn't tight: that fabric gives.
        let pressing = under == nil ? cloth.contact : cloth.positions.indices.map { i in
            cloth.contact[i] && self.distance(cloth.positions[i]) - margin - thickness < 0.004
        }
        mesh.strain = fitValues(stretch: cloth.stretch, contact: pressing, fabric: fabric, neighbours: neighbours)
        let ease = cloth.rest.indices.map { cutEase(tags[$0], cloth.rest[$0].y) }
        let report = self.report(cloth, contact: pressing, ease: ease, tags: tags, fit: fit, fabric: fabric)
        if case .trousers = fit.kind {
            // A hem resting on the shoe isn't a fit problem; the avatar has no shoes.
            for i in mesh.strain.indices where cloth.rest[i].y < ankleY + 0.015 { mesh.strain[i] = min(mesh.strain[i], 0.5) }
        }
        mesh.computeNormals()

        // Folds: loose fabric hanging in vertical folds, deepening towards the hem (more
        // and deeper for fluid fabrics), and extra length bunched at hems and cuffs.
        // A sewn garment's folds are its own (the simulation drapes it); only the
        // extra length's bunching at hems and cuffs is added.
        for i in mesh.positions.indices where !pinned[i] {
            let p = mesh.positions[i]
            var push: Float = 0
            if !fit.drapesFromFlat, let (amount, axis) = hang(tags[i], cloth.rest[i]), amount > 0.004 {
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
            // Exactly the finished garment, not within rounding of it.
            frames[frames.count - 1] = mesh.positions
        }

        (mesh.tones, mesh.toneWeight) = tones(shape, rest: cloth.rest, tags: tags, stretch: cloth.stretch,
                                              contact: pressing, ease: ease, fabric: fabric,
                                              neighbours: neighbours)
        mesh.sway = sway(shape, rest: cloth.rest, tags: tags, gap: cloth.gap, pinnedAbove: pinnedAbove, fabric: fabric)
        let cover: (Vec3) -> Float = under.map { inner in { p in min(cut(p), inner(p)) } } ?? cut
        let lines = fitLines(shape, mesh: mesh, tags: tags, cover: cover, report: report)
        let seams = stitches(fit, mesh: mesh, tags: tags)
        if case .trousers = fit.kind, let lowest = mesh.positions.filter({ $0.x > 0 }).min(by: { $0.y < $1.y }) {
            anchors[.hem] = Vec3(anchors[.hem]?.x ?? lowest.x, lowest.y, 0)
        }
        let shell = self.shell(pattern)
        let placed = placements(shape, lengthKnown: fit.lengthFromChart, sleeveKnown: fit.sleeveFromChart)
        return Dressed(mesh: mesh, seams: seams, anchors: anchors, cut: shell, report: report, frames: frames, lines: lines,
                       placements: placed)
    }

    /// The pattern piece each triangle is cut from, as a garment of this kind is sewn
    /// (Aldrich, "Metric Pattern Cutting"; GarmentCode's tee, pants and skirt panels):
    /// - a top: front and back bodice joined at the side and shoulder seams (a jacket or
    ///   coat's front in two halves, open down the middle), each sleeve one piece set into
    ///   its armhole;
    /// - trousers: a front and a back piece per leg, from the waistband to the hem, joined
    ///   at the outside and inside leg seams and down the middle front and back;
    /// - a skirt: a front and a back joined at the side seams.
    /// Front and back divide where the side seams run, at the middle of the body's depth
    /// (of the leg's, below the seat), as the drawn seams do.
    func panels(_ fit: Avatar.GarmentFit, mesh: Mesh, owner: (Vec3) -> Int) -> [Int] {
        let mid = { (y: Float) -> Float in self.torso.ring(at: max(y, self.crotchY)).center.z }
        var out: [Int] = []
        out.reserveCapacity(mesh.indices.count / 3)
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = mesh.positions[Int(mesh.indices[t])], b = mesh.positions[Int(mesh.indices[t + 1])]
            let c = mesh.positions[Int(mesh.indices[t + 2])]
            let p = (a + b + c) * (1.0 / 3)
            let part = owner(p)
            switch fit.kind {
            case .top:
                if part > 0 {
                    out.append(10 + part)
                } else if p.z >= mid(p.y) {
                    out.append(fit.style.isOuter && p.x < 0 ? 2 : 0)
                } else {
                    out.append(1)
                }
            case .trousers:
                let right = p.x >= 0 ? 0 : 2
                let depth = part == 0 ? mid(p.y) : self.legs[part - 1].knee.z
                out.append(right + (p.z >= depth ? 0 : 1))
            case .skirt:
                out.append(p.z >= mid(p.y) ? 0 : 1)
            }
        }
        return out
    }

    /// Where a garment of this kind usually ends, before its length moves it: a top just
    /// below the hips, a coat a little above the knee, a dress at the knee, a skirt just
    /// above it.
    func regularHem(_ fit: Avatar.GarmentFit) -> Float {
        usualHem(fit) - Float(fit.hemOffset / 100)
    }

    private func usualHem(_ fit: Avatar.GarmentFit) -> Float {
        switch (fit.kind, fit.style) {
        case (.skirt, _): kneeY + 0.03 * h
        case (.top, .coat): kneeY + 0.05 * h
        case (.top, .dress): kneeY
        default: crotchY + 0.035 * h
        }
    }

    /// A tube round both legs below the hips, as a skirt or a coat's skirt hangs: the hip
    /// section (half-width and depth from the torso's ring there) plus `ease`, widening by
    /// `flare` metres per metre down. Infinite above the hips, where the torso takes over.
    func tube(ease: Float, flare: Float) -> (Vec3) -> Float {
        let ring = torso.ring(at: hipY)
        let top = hipY
        let legsOut = legs.map { abs($0.ankle.x) + thighR * 0.5 }.max() ?? 0
        let knee = kneeY
        return { p in
            guard p.y < top else { return .greatestFiniteMagnitude }
            let grow = ease + flare * (top - p.y)
            // Never narrower than the stance (the legs stand apart a little), widening to
            // it gradually down to the knee so there's no shelf under the hips.
            let ramp = min(1, max(0, (top - p.y) / max(0.05, top - knee)))
            let a = ring.halfWidth + max(0, legsOut - ring.halfWidth) * ramp + grow, b = ring.halfDepth + grow
            let dx = (p.x - ring.center.x) / a, dz = (p.z - ring.center.z) / b
            return ((dx * dx + dz * dz).squareRoot() - 1) * min(a, b)
        }
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
        case .skirt:
            let waistband = (waistY + hipY) / 2
            let hem = mesh.positions.map(\.y).min() ?? 0
            lines.append(({ $0.y - (waistband - 0.035) }, [0], around(Vec3(0, 0, 0))))
            lines.append(({ $0.y - (hem + 0.014) }, [0], around(Vec3(0, 0, 0))))
            // Side seams.
            lines.append(({ p in p.z - mid(max(p.y, self.hipY)) }, [0], byHeight))
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
            if fit.style.isOuter {
                // Open down the front: a front edge each side of the middle from the lapels'
                // V to the hem, and the lapels from the collar down to the V.
                let vBottom = chestY - 0.03 * h, collarY = necklineTop - 0.02 * h
                let front = { (p: Vec3) -> Bool in p.z > mid(p.y) }
                for side: Float in [1, -1] {
                    lines.append(({ p in front(p) && p.y < vBottom ? p.x - side * 0.01 : .nan }, [0], byHeight))
                    lines.append(({ p in
                        guard front(p), p.y >= vBottom, p.y <= collarY, side * p.x >= 0 else { return .nan }
                        let t = (p.y - vBottom) / max(0.01, collarY - vBottom)
                        return abs(p.x) - (0.01 + t * 0.065)
                    }, [0], byHeight))
                }
            }
        }
        return lines.flatMap { contour($0.f, parts: $0.parts, mesh: mesh, tags: tags, dash: $0.dash) }
    }

    /// Moves points that lie inside the shown skin, or closer to it than `clearance`,
    /// out along the skin's normal at the nearest skin vertex (within 5 cm; further away
    /// a point isn't on this skin). Only for a body with its own skin (SOMA-X); a body
    /// drawn from its distance field has nothing finer to hold to.
    func liftOffSkin(_ points: inout [Vec3], clearance: Float) {
        guard let skin = surface, skin.normals.count == skin.positions.count else { return }
        let cell: Float = 0.025
        func key(_ p: Vec3) -> SIMD3<Int32> {
            SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
        }
        var grid: [SIMD3<Int32>: [Int]] = [:]
        for i in skin.positions.indices { grid[key(skin.positions[i]), default: []].append(i) }
        for i in points.indices {
            let p = points[i], k = key(p)
            var best = -1, bestD: Float = 0.05 * 0.05
            for dx: Int32 in -2...2 { for dy: Int32 in -2...2 { for dz: Int32 in -2...2 {
                for j in grid[k &+ SIMD3(dx, dy, dz)] ?? [] {
                    let d = p - skin.positions[j]
                    let dd = d.dot(d)
                    if dd < bestD { bestD = dd; best = j }
                }
            } } }
            guard best >= 0 else { continue }
            let n = skin.normals[best]
            let along = (p - skin.positions[best]).dot(n)
            if along < clearance { points[i] = p + n * (clearance - along) }
        }
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

    /// Taubin's λ|μ smoothing (1995): a shrinking and an inflating Laplacian step in turn,
    /// a low-pass filter on the surface that removes creases a few cells wide without the
    /// shrinkage plain Laplacian smoothing causes. An open edge (a hem, a cuff) is smoothed
    /// along itself only, so it straightens without being pulled up into the garment.
    static func smoothCloth(_ points: inout [Vec3], neighbours: [[Int]], boundary: Set<Int>, pinned: [Bool],
                            iterations: Int = 10, lambda: Float = 0.5, mu: Float = -0.53) {
        guard points.count == neighbours.count else { return }
        let ring: [[Int]] = neighbours.indices.map { i in
            boundary.contains(i) ? neighbours[i].filter { boundary.contains($0) } : neighbours[i]
        }
        var next = points
        for k in 0..<(2 * iterations) {
            let w = k % 2 == 0 ? lambda : mu
            for i in points.indices {
                let n = ring[i]
                guard !pinned[i], n.count >= 2 else { next[i] = points[i]; continue }
                var c = Vec3(0, 0, 0)
                for j in n { c = c + points[j] }
                c = c * (1 / Float(n.count))
                next[i] = points[i] + (c - points[i]) * w
            }
            swap(&points, &next)
        }
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
