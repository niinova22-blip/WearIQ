import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

@Suite struct AnthropometricPriorTests {
    private let prior = AnthropometricPrior()

    @Test func averageManIsPlausible() throws {
        let e = prior.estimate(heightCm: 178, weightKg: 80, sex: .male)
        #expect(e.count == 9)
        let chest = try #require(e[.chest])
        #expect((97...107).contains(chest.cm))
        #expect(chest.source == .estimated)
        #expect((84...96).contains(try #require(e[.waist]).cm))
        #expect((38...45).contains(try #require(e[.shoulderWidth]).cm))  // biacromial, ANSUR mean ≈ 41
        #expect((78...88).contains(try #require(e[.inseam]).cm))
    }

    @Test func averageWomanIsPlausible() throws {
        let e = prior.estimate(heightCm: 165, weightKg: 62, sex: .female)
        #expect((84...96).contains(try #require(e[.chest]).cm))
        #expect((92...104).contains(try #require(e[.hip]).cm))
    }

    @Test func heavierMeansLargerGirths() throws {
        let light = prior.estimate(heightCm: 178, weightKg: 65, sex: nil)
        let heavy = prior.estimate(heightCm: 178, weightKg: 100, sex: nil)
        for d in [BodyDimension.chest, .waist, .hip, .thigh] {
            #expect(try #require(heavy[d]).cm > (try #require(light[d]).cm) + 5)
        }
    }

    @Test func implausibleInputGivesNothing() {
        #expect(prior.estimate(heightCm: 50, weightKg: 70, sex: .male).isEmpty)
        #expect(prior.estimate(heightCm: 175, weightKg: 0, sex: .male).isEmpty)
    }

    @Test func extrapolationWidensUncertainty() throws {
        let inside = try #require(prior.estimate(heightCm: 175, weightKg: 80, sex: .male)[.chest])
        let outside = try #require(prior.estimate(heightCm: 175, weightKg: 160, sex: .male)[.chest])
        #expect(outside.uncertaintyCm > inside.uncertaintyCm * 1.4)
    }
}

@Suite struct MeasurementFusionTests {
    private func scan(_ cm: Double, _ u: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: u, source: .scan) }
    private func est(_ cm: Double, _ u: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: u, source: .estimated) }

    @Test func fillsMissingValues() {
        let (p, rejected) = MeasurementFusion.fuse(scan: BodyProfile(), prior: [.chest: est(100, 4)])
        #expect(p[.chest]?.source == .estimated)
        #expect(rejected.isEmpty)
    }

    @Test func agreeingValuesAreCombined() throws {
        let (p, _) = MeasurementFusion.fuse(scan: BodyProfile(values: [.chest: scan(104, 4)]), prior: [.chest: est(100, 4)])
        let c = try #require(p[.chest])
        #expect(abs(c.cm - 102) < 0.01)
        #expect(c.uncertaintyCm < 4)
        #expect(c.source == .scan)
    }

    @Test func wildScanValueIsReplaced() {
        let (p, rejected) = MeasurementFusion.fuse(scan: BodyProfile(values: [.waist: scan(140, 4)]), prior: [.waist: est(88, 5)])
        #expect(p[.waist]?.cm == 88)
        #expect(rejected == [.waist])
    }

    @Test func manualValuesAreNeverOverridden() {
        let (p, _) = MeasurementFusion.fuse(scan: BodyProfile(values: [.chest: .manual(130)]), prior: [.chest: est(100, 4)])
        #expect(p[.chest]?.cm == 130)
    }
}
