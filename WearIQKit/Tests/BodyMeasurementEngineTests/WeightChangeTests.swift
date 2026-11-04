import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

@Suite struct WeightChangeTests {
    private let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)

    private var profile: BodyProfile {
        var p = BodyProfile(values: [
            .height: .manual(175), .chest: MeasuredValue(cm: 98, uncertaintyCm: 1.5, source: .scan),
            .waist: MeasuredValue(cm: 86, uncertaintyCm: 1.5, source: .scan),
            .hip: MeasuredValue(cm: 100, uncertaintyCm: 1.5, source: .scan),
            .inseam: MeasuredValue(cm: 80, uncertaintyCm: 1.5, source: .scan),
        ], createdAt: measuredAt, weightKg: 75, sex: .male)
        p.assessments = [.waist: MeasurementAssessment(low: 84, high: 88)]
        return p
    }

    @Test func smallSwingsAreIgnored() {
        #expect(WeightChange.check(profile: profile, currentKg: 77, measuredAt: measuredAt.addingTimeInterval(86400)) == nil)
    }

    @Test func olderReadingsAreIgnored() {
        #expect(WeightChange.check(profile: profile, currentKg: 85, measuredAt: measuredAt.addingTimeInterval(-86400)) == nil)
    }

    @Test func heavierPeopleNeedABiggerChange() {
        #expect(WeightChange.threshold(forKg: 70) == 3)
        #expect(WeightChange.threshold(forKg: 120) == 4.8)
    }

    @Test func gainMovesGirthsNotLengths() throws {
        let change = try #require(WeightChange.check(profile: profile, currentKg: 81, measuredAt: measuredAt.addingTimeInterval(86400 * 30)))
        #expect(change.deltaKg == 6)
        let shifts = change.expectedShifts(for: profile)
        let waist = try #require(shifts[.waist])
        #expect(waist > 2 && waist < 10)
        #expect(shifts[.inseam] == nil)

        let estimated = change.estimatedProfile(from: profile, now: measuredAt.addingTimeInterval(86400 * 31))
        #expect(estimated[.waist]?.source == .estimated)
        #expect(estimated[.waist]!.cm > 86)
        #expect(estimated[.waist]!.uncertaintyCm > 1.5)
        #expect(estimated[.inseam] == profile[.inseam])
        #expect(estimated.weightKg == 81)
        #expect(estimated.assessments == nil)
    }

    @Test func lossShrinksGirths() throws {
        let change = try #require(WeightChange.check(profile: profile, currentKg: 70, measuredAt: measuredAt.addingTimeInterval(86400)))
        #expect(change.expectedShifts(for: profile)[.chest]! < 0)
    }
}
