import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

/// Synthetic person: 1 px = 0.1 cm, 180 cm tall (1800 px), floor at y = 1900, joints at
/// the stature fractions JointHeights expects (neck 0.818, shoulders 0.80, hips 0.52,
/// ankles 0.04).
private let front = ScanObservation(
    personHeightPx: 1800, floorY: 1900,
    joints: [
        .neck: Point2D(500, 427.6),
        .leftShoulder: Point2D(300, 460), .rightShoulder: Point2D(700, 460),  // 40 cm joint distance
        .leftElbow: Point2D(280, 760), .rightElbow: Point2D(720, 760),
        .leftWrist: Point2D(280, 1020), .rightWrist: Point2D(720, 1020),
        .root: Point2D(500, 964), .leftHip: Point2D(450, 964), .rightHip: Point2D(550, 964),
        .leftAnkle: Point2D(450, 1828), .rightAnkle: Point2D(550, 1828),
    ],
    levels: [
        .chest: LevelSample(y: 550, extentPx: 330),
        .waist: LevelSample(y: 860, extentPx: 290),
        .hip: LevelSample(y: 1000, extentPx: 350),
        .thigh: LevelSample(y: 1100, extentPx: 190),
    ],
    crotchY: 1080
)

private let side = ScanObservation(
    personHeightPx: 1800, floorY: 1900, joints: [.leftAnkle: Point2D(500, 1850)],
    levels: [
        .chest: LevelSample(y: 550, extentPx: 250),
        .waist: LevelSample(y: 860, extentPx: 230),
        .hip: LevelSample(y: 1000, extentPx: 270),
        .thigh: LevelSample(y: 1100, extentPx: 190),
    ]
)

@Suite struct BodyMeasurementTests {
    let engine = BodyMeasurementEngine()

    @Test func lengthsScaleWithHeight() throws {
        let p = try engine.measure(heightCm: 180, front: front, side: side)
        #expect(abs(p[.shoulderWidth]!.cm - 44) < 0.01)          // 40 cm × 1.10
        #expect(abs(p[.armLength]!.cm - (sqrt(904.0) + 26) * 1.05) < 0.01)
        #expect(abs(p[.inseam]!.cm - 82) < 0.01)
        #expect(abs(p[.outseam]!.cm - 93.6 * 1.157) < 0.01)
        #expect(abs(p[.torsoLength]!.cm - 53.64 * 0.87) < 0.01)
    }

    /// A mask that reaches 30% too far (a shadow under the feet) must not shrink lengths
    /// measured between joints.
    @Test func jointLengthsIgnoreAnOversizedMask() throws {
        var f = front
        f.personHeightPx = 1800 * 1.3
        f.floorY = 1900 + 1800 * 0.3
        let p = try engine.measure(heightCm: 180, front: f, side: side)
        #expect(abs(p[.shoulderWidth]!.cm - 44) < 0.01)
        #expect(abs(p[.armLength]!.cm - (sqrt(904.0) + 26) * 1.05) < 0.01)
        #expect(abs(BodyMeasurementEngine.skeletonToMaskRatio(f)! - 1 / 1.3) < 0.001)
        #expect(p[.height]?.source == .userProvided)
    }

    @Test func girthUsesEllipseFromWidthAndDepth() throws {
        let p = try engine.measure(heightCm: 180, front: front, side: side)
        let expected = BodyMeasurementEngine.ellipsePerimeter(a: 16.5, b: 12.5) * 1.06
        #expect(abs(p[.chest]!.cm - expected) < 0.01)
        #expect((95...102).contains(p[.chest]!.cm))
    }

    @Test func ellipseOfCircleIsTwoPiR() {
        #expect(abs(BodyMeasurementEngine.ellipsePerimeter(a: 10, b: 10) - 20 * .pi) < 1e-9)
    }

    @Test func frontOnlyGirthIsLessConfident() throws {
        let both = try engine.measure(heightCm: 180, front: front, side: side)
        let frontOnly = try engine.measure(heightCm: 180, front: front, side: nil)
        let relBoth = both[.waist]!.uncertaintyCm / both[.waist]!.cm
        let relFront = frontOnly[.waist]!.uncertaintyCm / frontOnly[.waist]!.cm
        #expect(relFront > relBoth)
        #expect(frontOnly[.waist]!.confidence == .low)
    }

    @Test func heightUncertaintyPropagates() throws {
        let sure = try engine.measure(heightCm: 180, heightUncertaintyCm: 0.5, front: front, side: side)
        let unsure = try engine.measure(heightCm: 180, heightUncertaintyCm: 5, front: front, side: side)
        #expect(unsure[.inseam]!.uncertaintyCm > sure[.inseam]!.uncertaintyCm)
    }

    @Test func missingCrotchFallsBackWithMoreUncertainty() throws {
        var f = front
        f.crotchY = nil
        let p = try engine.measure(heightCm: 180, front: f, side: side)
        let withCrotch = try engine.measure(heightCm: 180, front: front, side: side)
        #expect(p[.inseam]!.uncertaintyCm > withCrotch[.inseam]!.uncertaintyCm)
    }

    @Test func rejectsInvalidInput() {
        #expect(throws: BodyMeasurementError.invalidHeight) {
            try engine.measure(heightCm: 20, front: front, side: nil)
        }
        var cropped = front
        cropped.joints[.leftAnkle] = nil
        cropped.joints[.rightAnkle] = nil
        #expect(throws: BodyMeasurementError.personNotFullyVisible) {
            try engine.measure(heightCm: 180, front: cropped, side: nil)
        }
    }
}
