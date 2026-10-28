import Testing
@testable import FitEngine
import WearIQCore

@Suite struct MeasurementComparisonTests {
    private func v(_ cm: Double, _ u: Double = 0.5, _ s: MeasurementSource = .manual) -> MeasuredValue {
        MeasuredValue(cm: cm, uncertaintyCm: u, source: s)
    }

    @Test func realChangeVersusNoise() {
        let before = BodyProfile(values: [.waist: v(86), .chest: v(100, 4, .scan), .hip: v(100)])
        let after = BodyProfile(values: [.waist: v(91), .chest: v(105, 4, .scan), .hip: v(100.8)])
        let changes = Dictionary(uniqueKeysWithValues: MeasurementComparison.compare(before, after).map { ($0.dimension, $0) })
        #expect(changes[.waist]?.trend == .increased)                // +5 cm, precise tape values
        #expect(changes[.chest]?.trend == .withinMeasurementError)   // +5 cm but ±4 cm scans → noise
        #expect(changes[.hip]?.trend == .withinMeasurementError)     // below tape precision
        #expect(changes[.waist]?.deltaCm == 5)
    }

    @Test func decreaseDetected() {
        let changes = MeasurementComparison.compare(BodyProfile(values: [.waist: v(90)]), BodyProfile(values: [.waist: v(84)]))
        #expect(changes.first?.trend == .decreased)
    }

    @Test func pantsWaistBecomesTight() throws {
        let pants = GarmentSpec(category: .pants, chartKind: .garment, sizes: [
            SizeEntry(label: "32", values: [.waist: v(88), .hip: v(106)]),
            SizeEntry(label: "34", values: [.waist: v(93), .hip: v(110)]),
        ])
        let before = BodyProfile(values: [.waist: v(86), .hip: v(100)])
        let after = BodyProfile(values: [.waist: v(91), .hip: v(100)])
        let impact = try #require(MeasurementComparison.impact(of: pants, size: "32", before: before, after: after))
        #expect(impact.changedRegions.contains { $0.region == .waist && ($0.to == .tight || $0.to == .slightlyTight) })
        #expect(impact.recommendationChanged)
        #expect(!impact.changedRegions.contains { $0.region == .hip })
    }

    @Test func noImpactWhenOnlyNoiseChanged() {
        let pants = GarmentSpec(category: .pants, chartKind: .garment, sizes: [SizeEntry(label: "32", values: [.waist: v(88)])])
        let before = BodyProfile(values: [.waist: v(86, 4, .scan)])
        let after = BodyProfile(values: [.waist: v(89, 4, .scan)])
        #expect(MeasurementComparison.impact(of: pants, size: "32", before: before, after: after) == nil)
    }
}
