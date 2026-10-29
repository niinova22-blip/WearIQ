import Testing
@testable import BodyMeasurementEngine

/// Draws a synthetic A-pose silhouette: 400×1000 px, head top at y=100, feet at y=900.
private func frontMask() -> BinaryMask {
    let w = 400, h = 1000
    var bits = [Bool](repeating: false, count: w * h)
    func fill(_ rows: Range<Int>, _ cols: Range<Int>) {
        for y in rows { for x in cols { bits[y * w + x] = true } }
    }
    func torso(_ rows: Range<Int>, width: Int) { fill(rows, (200 - width / 2)..<(200 + width / 2)) }
    fill(100..<200, 180..<220)      // head
    torso(200..<300, width: 100)    // shoulders/chest
    torso(300..<380, width: 90)
    torso(380..<420, width: 80)     // waist (narrowest)
    torso(420..<470, width: 96)
    torso(470..<510, width: 104)    // hips (widest)
    fill(510..<901, 150..<195)      // left leg, 45 px
    fill(510..<901, 205..<250)      // right leg, 45 px
    fill(230..<450, 70..<90)        // arms held away from the body
    fill(230..<450, 310..<330)
    return BinaryMask(width: w, height: h, bits: bits)
}

private let frontJoints: [BodyJoint: Point2D] = [
    .leftShoulder: Point2D(150, 220), .rightShoulder: Point2D(250, 220),
    .root: Point2D(200, 480), .leftKnee: Point2D(180, 700), .rightKnee: Point2D(220, 700),
    .leftAnkle: Point2D(172, 880), .rightAnkle: Point2D(228, 880),
]

@Suite struct SilhouetteAnalyzerTests {
    let analyzer = SilhouetteAnalyzer()

    @Test func findsHeightAndLevels() throws {
        let o = try analyzer.analyzeFront(mask: frontMask(), joints: frontJoints)
        #expect(o.personHeightPx == 800)
        #expect(o.floorY == 900)
        #expect(o.levels[.chest]?.extentPx == 100)     // arms excluded
        #expect(o.levels[.waist]?.extentPx == 80)
        #expect((380..<420).contains(Int(o.levels[.waist]?.y ?? 0)))
        #expect(o.levels[.hip]?.extentPx == 104)
        #expect(o.crotchY == 510)
        #expect(o.levels[.thigh]?.extentPx == 45)      // one leg
    }

    @Test func sideLevelsUseSameRelativeHeight() throws {
        let front = try analyzer.analyzeFront(mask: frontMask(), joints: frontJoints)
        // Side photo framed differently: head at y=50, feet at 850, torso 70 px deep.
        let w = 300, h = 900
        var bits = [Bool](repeating: false, count: w * h)
        for y in 50..<851 {
            let depth = y < 480 ? 70 : 60
            for x in (150 - depth / 2)..<(150 + depth / 2) { bits[y * w + x] = true }
        }
        let side = try analyzer.analyzeSide(mask: BinaryMask(width: w, height: h, bits: bits), front: front)
        #expect(side.personHeightPx == 800)
        #expect(side.levels[.chest]?.y == 248)   // front chest at 198/800 of the height
        #expect(side.levels[.chest]?.extentPx == 70)
        #expect(side.levels[.thigh]?.extentPx == 60)
    }

    @Test func endToEndProducesPlausibleProfile() throws {
        let front = try analyzer.analyzeFront(mask: frontMask(), joints: frontJoints)
        let p = try BodyMeasurementEngine().measure(heightCm: 180, front: front, side: nil)
        // 800 px = 180 cm → waist 80 px = 18 cm wide.
        #expect(p[.waist] != nil)
        #expect(abs(p[.inseam]!.cm - 390 * 180 / 800) < 0.01)
    }

    @Test func emptyMaskThrows() {
        let empty = BinaryMask(width: 10, height: 10, bits: [Bool](repeating: false, count: 100))
        #expect(throws: SilhouetteError.noPerson) {
            try analyzer.analyzeFront(mask: empty, joints: frontJoints)
        }
    }

    @Test func missingJointsThrow() {
        #expect(throws: SilhouetteError.missingJoints([.root])) {
            try analyzer.analyzeFront(mask: frontMask(), joints: [.leftShoulder: Point2D(150, 220), .rightShoulder: Point2D(250, 220)])
        }
    }

    @Test func maskFromBytesAppliesThreshold() {
        let bytes: [UInt8] = [0, 200, 127, 0, /* padding */ 255, 255, 129, 0, 0, 0]
        let mask = bytes.withUnsafeBytes { BinaryMask(width: 3, height: 2, bytesPerRow: 5, bytes: $0) }
        #expect(mask[1, 0])
        #expect(!mask[2, 0])
        #expect(mask[0, 1] && mask[1, 1] && !mask[2, 1])
    }
}

@Suite struct PoseGuidanceTests {
    let guidance = PoseGuidance()

    private func joints(_ pairs: [BodyJoint: (Double, Double)]) -> [BodyJoint: DetectedJoint] {
        pairs.mapValues { DetectedJoint(Point2D($0.0, $0.1), confidence: 0.9) }
    }

    private let goodFront: [BodyJoint: (Double, Double)] = [
        .nose: (0.5, 0.12), .neck: (0.5, 0.18),
        .leftShoulder: (0.42, 0.2), .rightShoulder: (0.58, 0.2),
        .leftHip: (0.45, 0.5), .rightHip: (0.55, 0.5),
        .leftWrist: (0.33, 0.48), .rightWrist: (0.67, 0.48),
        .leftAnkle: (0.46, 0.88), .rightAnkle: (0.54, 0.88),
    ]

    @Test func acceptsGoodFrontPose() {
        #expect(guidance.issue(for: joints(goodFront), pose: .front) == nil)
    }

    @Test func armsAgainstBody() {
        var j = goodFront
        j[.leftWrist] = (0.45, 0.5)
        #expect(guidance.issue(for: joints(j), pose: .front) == .armsTooCloseToBody)
    }

    @Test func tooFarAndTooClose() {
        let far = goodFront.mapValues { (0.5 + ($0.0 - 0.5) * 0.5, 0.3 + $0.1 * 0.4) }
        #expect(guidance.issue(for: joints(far), pose: .front) == .tooFar)
        var close = goodFront
        close[.nose] = (0.5, 0.07)
        close[.leftAnkle] = (0.46, 0.995)
        #expect(guidance.issue(for: joints(close), pose: .front) == .feetNotVisible)
    }

    @Test func feetMissing() {
        var j = goodFront
        j[.leftAnkle] = nil
        j[.rightAnkle] = nil
        #expect(guidance.issue(for: joints(j), pose: .front) == .feetNotVisible)
    }

    @Test func sidePose() {
        var side = goodFront
        side[.leftShoulder] = (0.49, 0.2)
        side[.rightShoulder] = (0.52, 0.2)
        #expect(guidance.issue(for: joints(side), pose: .side) == nil)
        #expect(guidance.issue(for: joints(goodFront), pose: .side) == .notSideways)
    }

    @Test func lowConfidenceIsIgnored() {
        let j = goodFront.mapValues { DetectedJoint(Point2D($0.0, $0.1), confidence: 0.1) }
        #expect(guidance.issue(for: j, pose: .front) == .noPerson)
    }
}
