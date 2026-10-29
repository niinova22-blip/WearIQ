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
}
