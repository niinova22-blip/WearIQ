import Foundation
import WearIQCore

/// The user's body as a 3D avatar built from their measurements, and a garment drawn on
/// it from the fit analysis: girths become how far the fabric stands off the body,
/// lengths decide where hems and cuffs end. Longer than the body, the extra length
/// bunches into folds (a trouser hem stacking on the shoe, a sleeve over the hand);
/// shorter, skin shows. A shoulder seam wider than the shoulders sits down the arm.
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

        public init(kind: Kind) { self.kind = kind }
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

    init(_ m: Avatar.Measurements) {
        self.m = m
        h = Float(m.height / 100)
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
        armStart = (Vec3(shoulderHalf * 0.92, shoulderY, 0), Vec3(-shoulderHalf * 0.92, shoulderY, 0))
        armLength = Float(m.armLength / 100)
        upperArmR = 0.0275 * h
    }

    private func ring(_ y: Float, _ size: (Float, Float), grow: Float = 0) -> Ring {
        Ring(center: Vec3(0, y, 0), halfWidth: size.0 + grow, halfDepth: size.1 + grow)
    }

    private var torsoRings: [Ring] {
        [
            ring(crotchY, (hip.0 * 0.92, hip.1 * 0.85)),
            ring(hipY, hip),
            ring(waistY, waist),
            ring(chestY, chest),
            ring(armpitY, (chest.0 * 0.98, chest.1 * 0.95)),
            ring(shoulderY, (shoulderHalf, chest.1 * 0.72)),
            ring(0.82 * h, (shoulderHalf * 0.55, chest.1 * 0.55)),
            ring(neckY, (0.032 * h, 0.034 * h)),
        ]
    }

    private var legRadii: [Float] {
        [thighR, thighR * 0.9, thighR * 0.76, thighR * 0.62, thighR * 0.64, thighR * 0.5, thighR * 0.4]
    }

    func bodyMesh() -> Mesh {
        var mesh = Shapes.loft(torsoRings)
        // Neck and head.
        mesh.append(Shapes.tube(from: Vec3(0, neckY - 0.01 * h, 0), to: Vec3(0, 0.87 * h, 0), radii: [0.034 * h, 0.031 * h]))
        mesh.append(Shapes.ellipsoid(center: Vec3(0, headY, 0.005 * h), radii: Vec3(0.045 * h, 0.064 * h, 0.055 * h)))
        // Legs and feet.
        for side: Float in [1, -1] {
            let top = Vec3(side * legX, crotchY + 0.01 * h, 0), bottom = Vec3(side * legX * 0.85, ankleY, 0)
            mesh.append(Shapes.tube(from: top, to: bottom, radii: legRadii))
            mesh.append(Shapes.ellipsoid(center: Vec3(side * legX * 0.85, 0.022 * h, 0.035 * h),
                                         radii: Vec3(0.028 * h, 0.022 * h, 0.075 * h)))
        }
        // Arms and hands.
        for (start, dir) in [(armStart.0, armDir.0), (armStart.1, armDir.1)] {
            let wrist = start + dir * armLength
            mesh.append(Shapes.tube(from: start, to: wrist,
                                    radii: [upperArmR, upperArmR * 0.95, upperArmR * 0.82, upperArmR * 0.74, upperArmR * 0.66, upperArmR * 0.55]))
            mesh.append(Shapes.ellipsoid(center: wrist + dir * (0.054 * h), radii: Vec3(0.022 * h, 0.054 * h, 0.012 * h)))
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

    /// Radii that bunch into folds over the last part of a tube: `folds` bulges.
    private func folded(_ radii: [Float], folds: Int, bulge: Float) -> [Float] {
        guard folds > 0 else { return radii }
        var r = radii
        let base = radii.last ?? 0
        for k in 0..<folds * 2 { r.append(base * (k % 2 == 0 ? 1 + bulge : 1.0)) }
        return r
    }

    func garmentMesh(_ fit: Avatar.GarmentFit) -> (Mesh, [Avatar.Anchor: Vec3]) {
        // Ease in circumference spreads as Δ / 2π all round; a little always stands off.
        func off(_ easeCm: Double) -> Float { max(0.004, Float(easeCm / 100) / (2 * .pi)) }
        var mesh = Mesh()
        var anchors: [Avatar.Anchor: Vec3] = [:]
        switch fit.kind {
        case .trousers:
            let waistband = (waistY + hipY) / 2
            let hipOff = off(fit.hipEase), waistOff = off(fit.waistEase), thighOff = off(fit.thighEase)
            let seat = [
                ring(crotchY - 0.01 * h, (hip.0 * 0.92, hip.1 * 0.86), grow: hipOff),
                ring(hipY, hip, grow: hipOff),
                ring(waistband, ((hip.0 + waist.0) / 2, (hip.1 + waist.1) / 2), grow: waistOff),
            ]
            mesh.append(Shapes.loft(seat))
            // Longer than the leg: the hem reaches the floor and the rest stacks in folds.
            // Shorter: the hem sits above the ankle.
            let extra = Float(fit.lengthDelta / 100)
            let hemY = extra >= 0 ? max(0.012 * h, ankleY - extra) : ankleY - extra
            let stacked = max(0, extra - (ankleY - 0.012 * h))
            let folds = min(5, Int((stacked * 100 / 1.8).rounded(.up)))
            for side: Float in [1, -1] {
                let top = Vec3(side * legX, crotchY + 0.005 * h, 0)
                let bottom = Vec3(side * legX * 0.85, hemY, 0)
                let radii = legRadii.map { $0 + thighOff * 0.7 + 0.006 }
                mesh.append(Shapes.tube(from: top, to: bottom, radii: folded(radii, folds: folds, bulge: 0.35), capped: false))
            }
            anchors[.hem] = Vec3(legX * 0.85 + thighR * 0.5, hemY, 0)
            anchors[.waist] = Vec3(waist.0 + waistOff, waistband, 0)
            anchors[.hip] = Vec3(hip.0 + hipOff, hipY, 0)
        case let .top(longSleeves):
            let chestOff = off(fit.chestEase), waistOff = off(fit.waistEase), hipOff = off(max(fit.hipEase, fit.waistEase))
            // A regular top ends just below the hips; longer or shorter moves the hem.
            let hemY = max(0.38 * h, crotchY + 0.035 * h - Float(fit.lengthDelta / 100))
            let dropped = Float(max(0, fit.shoulderDelta) / 200)
            let shell = [
                ring(hemY, (hip.0, hip.1), grow: hipOff),
                ring(hipY, hip, grow: hipOff),
                ring(waistY, waist, grow: waistOff),
                ring(chestY, chest, grow: chestOff),
                ring(armpitY, (chest.0 * 0.98, chest.1 * 0.95), grow: chestOff),
                ring(shoulderY, (shoulderHalf + dropped, chest.1 * 0.72), grow: chestOff * 0.5),
                ring(0.82 * h, (shoulderHalf * 0.55, chest.1 * 0.55), grow: 0.004),
                ring(neckY - 0.005 * h, (0.036 * h, 0.038 * h), grow: 0.003),
            ]
            mesh.append(Shapes.loft(shell))
            // Sleeves start at the shoulder seam: down the arm when the shoulder is dropped.
            let sleeveLength = longSleeves ? armLength + Float(fit.sleeveDelta / 100) : 0.36 * armLength
            let overHand = max(0, sleeveLength - armLength)
            let folds = longSleeves ? min(4, Int((overHand * 100 / 1.5).rounded(.up))) : 0
            for (start, dir) in [(armStart.0, armDir.0), (armStart.1, armDir.1)] {
                let seam = start + dir * dropped
                let end = start + dir * min(sleeveLength, armLength + 0.04 * h)
                let ease = upperArmR * 0.35 + chestOff * 0.4
                let radii: [Float] = longSleeves
                    ? [upperArmR + ease, upperArmR * 0.95 + ease, upperArmR * 0.8 + ease, upperArmR * 0.7 + ease]
                    : [upperArmR + ease, upperArmR * 0.97 + ease]
                mesh.append(Shapes.tube(from: seam, to: end, radii: folded(radii, folds: folds, bulge: 0.3), capped: false))
                if anchors[.sleeveEnd] == nil { anchors[.sleeveEnd] = end }
            }
            anchors[.hem] = Vec3(hip.0 + hipOff, hemY, 0)
            anchors[.chest] = Vec3(chest.0 + chestOff, chestY, 0)
            anchors[.waist] = Vec3(waist.0 + waistOff, waistY, 0)
            anchors[.shoulder] = Vec3(shoulderHalf + dropped, shoulderY, 0)
        }
        return (mesh, anchors)
    }
}
