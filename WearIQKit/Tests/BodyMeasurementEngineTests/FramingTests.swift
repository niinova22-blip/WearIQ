import Testing
@testable import BodyMeasurementEngine

@Suite struct FramingTests {
    func reading(top: Double, floor: Double, left: Double, right: Double) -> FrameReading {
        FrameReading(top: top, floor: floor, centerX: 0.5, levels: [:],
                     outline: [OutlineRow(y: 0.4, left: left, right: right)])
    }

    @Test func handsRunningOffTheSideAreSeen() {
        #expect(StopGuide.cutEdges(reading(top: 0.1, floor: 0.6, left: 0.05, right: 0.95)).isEmpty)
        #expect(StopGuide.cutEdges(reading(top: 0.1, floor: 0.6, left: 0, right: 0.95)) == .left)
        #expect(StopGuide.cutEdges(reading(top: 0, floor: 1, left: 0.1, right: 1)) == [.top, .bottom, .right])
    }
}
