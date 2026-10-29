import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

@Suite struct StationScanTests {
    // Half width and half depth (cm) of elliptical cross-sections.
    private let shapes: [BodyLevel: (Double, Double)] = [.chest: (17, 12), .waist: (15, 11), .hip: (18, 13)]

    private func width(_ level: BodyLevel, degrees: Double) -> Double {
        let (a, b) = shapes[level]!
        let t = degrees * .pi / 180
        return 2 * (a * a * cos(t) * cos(t) + b * b * sin(t) * sin(t)).squareRoot()
    }

    private func perimeter(_ level: BodyLevel) -> Double {
        let (a, b) = shapes[level]!
        let h = (a - b) * (a - b) / ((a + b) * (a + b))
        return Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
    }

    private func widths(at degrees: Double) -> [BodyLevel: Double] {
        Dictionary(uniqueKeysWithValues: shapes.keys.map { ($0, width($0, degrees: degrees)) })
    }

    @Test func eightStopsGiveTapeGirths() throws {
        var scan = StationScan()
        for i in 0..<8 { scan.record(widths(at: Double(i) * 45), at: i) }
        let girths = scan.girths()
        for level in shapes.keys {
            let measured = try #require(girths[level]).cm
            #expect(abs(measured - perimeter(level)) / perimeter(level) < 0.01, "\(level)")
        }
    }

    @Test func stopsTurnedOffByFifteenDegreesStillWork() throws {
        var scan = StationScan()
        let offsets: [Double] = [0, 12, -15, 10, -8, 15, -12, 5]
        for i in 0..<8 { scan.record(widths(at: Double(i) * 45 + offsets[i]), at: i) }
        let waist = try #require(scan.girths()[.waist]).cm
        #expect(abs(waist - perimeter(.waist)) / perimeter(.waist) < 0.025)
    }

    @Test func missedStopTakesTheOppositeOne() throws {
        var scan = StationScan()
        for i in 0..<8 where i != 2 && i != 5 { scan.record(widths(at: Double(i) * 45), at: i) }
        #expect(scan.count(.hip) == 6)
        let hip = try #require(scan.girths()[.hip]).cm
        #expect(abs(hip - perimeter(.hip)) / perimeter(.hip) < 0.01)
    }

    @Test func armsAgainstTheChestAreIgnored() throws {
        var scan = StationScan()
        for i in 0..<8 {
            var w = widths(at: Double(i) * 45)
            // Arms hanging against the chest add two arm widths seen from the front and back.
            if i % 4 == 0 { w[.chest]! += 18 }
            #expect(StationScan.armsAgainstChest(w, at: i) == (i % 4 == 0), "stop \(i)")
            scan.record(w, at: i)
        }
        let chest = try #require(scan.girths()[.chest]).cm
        #expect(abs(chest - perimeter(.chest)) / perimeter(.chest) < 0.02, "\(chest) vs \(perimeter(.chest))")
    }

    @Test func frontAndBackRebuiltFromNeighbours() throws {
        var scan = StationScan()
        for i in 0..<8 {
            var w = widths(at: Double(i) * 45)
            if i == 0 || i == 4 { w[.chest] = nil }
            scan.record(w, at: i)
        }
        let chest = try #require(scan.girths()[.chest]).cm
        #expect(abs(chest - perimeter(.chest)) / perimeter(.chest) < 0.01)
    }

    @Test func tooFewStopsGiveNothing() {
        var scan = StationScan()
        for i in 0..<5 { scan.record(widths(at: Double(i) * 45), at: i) }
        #expect(!scan.isMeasured(.waist))
        #expect(scan.girths().isEmpty)
    }

    @Test func notTurningGivesNothing() {
        var scan = StationScan()
        for i in 0..<8 { scan.record(widths(at: 0), at: i) }
        #expect(scan.girths().isEmpty)
    }

    @Test func neighbouringStopsDiffer() {
        var scan = StationScan()
        scan.record(widths(at: 0), at: 0)
        #expect(scan.differs(widths(at: 45), from: 0))
        #expect(!scan.differs(widths(at: 3), from: 0))
    }

    // MARK: Stop fit

    /// Arm span seen at a body rotation: |cos θ| of the span, never below the body depth.
    private func span(_ degrees: Double) -> Double {
        max(0.22, abs(cos(degrees * .pi / 180)))
    }

    @Test func eachStopAcceptsItsOwnPosition() {
        for i in 0..<8 {
            #expect(StopGuide.fit(station: i, spanRatio: span(Double(i) * 45), shoulderRatio: nil) == .ok, "stop \(i)")
        }
    }

    @Test func standingStillAtTheLastStopIsNotTheNext() {
        // Not turning: each stop sees the previous stop's position.
        for i in 1..<8 {
            #expect(StopGuide.fit(station: i, spanRatio: span(Double(i - 1) * 45), shoulderRatio: nil) != .ok, "stop \(i)")
        }
    }

    @Test func turningTooFarIsCalledOut() {
        #expect(StopGuide.fit(station: 1, spanRatio: span(90), shoulderRatio: 0.2) == .turnBack)
        #expect(StopGuide.fit(station: 2, spanRatio: span(20), shoulderRatio: nil) == .turnFurther)
    }

    @Test func droppedArmsAreCalledOut() {
        // Facing the camera with the arms down: narrow outline but wide shoulders.
        #expect(StopGuide.fit(station: 2, spanRatio: 0.3, shoulderRatio: 1) == .openArms)
        #expect(StopGuide.fit(station: 4, spanRatio: 0.3, shoulderRatio: 1) == .openArms)
    }

    // MARK: Clothing

    @Test func bareArmsAndBodyPass() {
        // 173 cm, 70 kg man: arm diameter about 0.057 of stature, waist 0.88 of hips.
        #expect(ClothingCheck.findings(armThickness: 0.057, waistWidthCm: 29, hipWidthCm: 33, bmi: 23.4, sex: .male).isEmpty)
    }

    @Test func sweatshirtIsCaught() {
        let found = ClothingCheck.findings(armThickness: 0.085, waistWidthCm: 36, hipWidthCm: 33, bmi: 23.4, sex: .male)
        #expect(found.contains(.looseSleeves))
        #expect(found.contains(.looseTop))
    }

    @Test func heavierBodiesAreNotFlagged() {
        // BMI 34: thicker arms and a fuller waist are the body, not the clothes.
        #expect(ClothingCheck.findings(armThickness: 0.075, waistWidthCm: 36, hipWidthCm: 37, bmi: 34, sex: .male).isEmpty)
    }

    // MARK: Stillness

    private func reading(waist: Double, center: Double = 0.5) -> FrameReading {
        let level = LevelReading(y: 0.4, left: 0.4, right: 0.6, widthCm: waist)
        return FrameReading(top: 0.1, floor: 0.9, centerX: center, levels: [.waist: level, .hip: level])
    }

    @Test func standingStillIsDetected() throws {
        var detector = StillnessDetector()
        for i in 0..<6 { detector.add(reading(waist: 30 + Double(i % 2) * 0.3), time: Double(i) / 6) }
        let widths = try #require(detector.stillWidths(at: 5.0 / 6))
        #expect(abs(widths[.waist]! - 30.15) < 0.2)
    }

    @Test func turningIsNotStill() {
        var detector = StillnessDetector()
        for i in 0..<6 { detector.add(reading(waist: 30 - Double(i) * 1.2), time: Double(i) / 6) }
        #expect(detector.stillWidths(at: 5.0 / 6) == nil)
    }

    @Test func walkingSidewaysIsNotStill() {
        var detector = StillnessDetector()
        for i in 0..<6 { detector.add(reading(waist: 30, center: 0.4 + Double(i) * 0.02), time: Double(i) / 6) }
        #expect(detector.stillWidths(at: 5.0 / 6) == nil)
    }

    @Test func tooShortIsNotStill() {
        var detector = StillnessDetector()
        for i in 0..<2 { detector.add(reading(waist: 30), time: Double(i) / 6) }
        #expect(detector.stillWidths(at: 1.0 / 6) == nil)
    }

    @Test func armsDownFromThePose() {
        func pose(wristDrop: Double?, elbowDrop: Double) -> FrameReading {
            var r = FrameReading(top: 0.1, floor: 0.9, centerX: 0.5, levels: [:])
            r.joints = [.leftShoulder: Point2D(0.45, 0.25), .leftElbow: Point2D(0.35, 0.25 + elbowDrop * 0.8)]
            if let wristDrop { r.joints[.leftWrist] = Point2D(0.3, 0.25 + wristDrop * 0.8) }
            return r
        }
        #expect(!StopGuide.armsDown(pose(wristDrop: 0.02, elbowDrop: 0.01)))   // held out
        #expect(StopGuide.armsDown(pose(wristDrop: 0.33, elbowDrop: 0.17)))    // hanging
        #expect(StopGuide.armsDown(pose(wristDrop: nil, elbowDrop: 0.16)))     // wrist hidden
        #expect(!StopGuide.armsDown(FrameReading(top: 0.1, floor: 0.9, centerX: 0.5, levels: [:])))
    }
}
