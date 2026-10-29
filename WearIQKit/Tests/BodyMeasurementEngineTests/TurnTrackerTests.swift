import Foundation
import Testing
@testable import BodyMeasurementEngine

@Suite struct TurnTrackerTests {
    /// Folded axis angle of a body rotated by `degrees` from facing the camera.
    private func fold(_ degrees: Double) -> Double {
        let r = degrees * .pi / 180
        return atan2(abs(sin(r)), abs(cos(r))) * 180 / .pi
    }

    private let all: Set<BodyLevel> = [.chest, .waist, .hip]

    @Test func fullTurnFillsEverySectorAndRegion() {
        var tracker = TurnTracker()
        var sectors: [Int] = []
        for i in 0...90 {
            // 4° per frame with ±3° pose jitter.
            let noise = Double((i * 37) % 7 - 3)
            tracker.add(axisAngle: max(0, fold(Double(i) * 4) + noise), measured: all, time: Double(i) / 6)
            sectors.append(tracker.completedSectors)
        }
        #expect(tracker.quarters == 4)
        #expect(tracker.completedSectors == TurnTracker.sectorCount)
        #expect(tracker.isComplete)
        // Sectors only ever fill forwards.
        #expect(sectors == sectors.sorted())
    }

    @Test func standingStillDoesNotProgress() {
        var tracker = TurnTracker()
        for i in 0..<60 {
            tracker.add(axisAngle: Double(i % 5) * 2, measured: all, time: Double(i) / 6)
        }
        #expect(tracker.quarters == 0)
        #expect(tracker.rotation < 30)
        #expect(!tracker.isComplete)
        #expect(tracker.idle(at: 10) > 5)
    }

    @Test func halfTurnIsHalfway() {
        var tracker = TurnTracker()
        for i in 0...45 { tracker.add(axisAngle: fold(Double(i) * 4), measured: all, time: Double(i) / 6) }
        #expect(tracker.quarters == 2)
        #expect(abs(tracker.rotation - 180) < 30)
    }

    @Test func regionsTurnGreenOnlyWhenSeenFromEveryDirection() {
        var tracker = TurnTracker()
        // Chest only measured while near facing the camera (arms in the way side-on).
        for i in 0...90 {
            let angle = fold(Double(i) * 4)
            tracker.add(axisAngle: angle, measured: angle < 40 ? all : [.waist, .hip], time: Double(i) / 6)
        }
        #expect(tracker.coverage(.waist) == 1)
        #expect(tracker.coverage(.chest) < 1)
        #expect(!tracker.isComplete)
    }

    @Test func framesWithoutAngleAreIgnored() {
        var tracker = TurnTracker()
        for i in 0..<30 { tracker.add(axisAngle: nil, measured: all, time: Double(i)) }
        #expect(tracker.rotation == 0)
        #expect(tracker.coverage(.hip) == 0)
    }
}
