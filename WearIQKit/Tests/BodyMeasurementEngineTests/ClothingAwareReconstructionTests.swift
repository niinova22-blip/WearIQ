import Foundation
import Testing
import WearIQCore
@testable import BodyMeasurementEngine

@Suite struct ClothingAwareReconstructionTests {
    let engine = ClothingAwareReconstruction()
    let waistPrior = MeasuredValue(cm: 84, uncertaintyCm: 5, source: .estimated)

    @Test func fittedClothesKeepTheOutline() {
        // Fitted: the outline is the body, give or take the fabric.
        let e = engine.reconstruct(outline: 88, expected: waistPrior,
                                   coverPrior: ClothingAwareReconstruction.coverPrior(attire: .fitted, region: .waist))
        #expect(abs(e.value.cm - 87) < 1.2)
        #expect(e.value.confidence >= .medium)
        #expect(e.assessment.high - e.assessment.low < 10)
        #expect([ClothingCover.skin, .fitted].contains(e.likeliestCover))
    }

    @Test func looseTopFallsBackTowardsTheStatisticsWithAWideRange() {
        // The device scan: a loose T-shirt read the waist 10 cm above the statistics.
        let e = engine.reconstruct(outline: 94, expected: waistPrior,
                                   coverPrior: ClothingAwareReconstruction.coverPrior(attire: .everyday, region: .waist))
        #expect(e.value.cm < 90)                      // not the outline
        #expect(e.value.cm > waistPrior.cm - 1)       // but not below what the body likely is
        #expect(e.assessment.low < 84 && e.assessment.high > 88)
        #expect(e.value.confidence <= .medium)
        #expect(e.value.uncertaintyCm > 3.5)
        #expect(e.likeliestCover > .fitted)
        #expect((e.assessment.clothingEffectCm ?? 0) > 4)
    }

    @Test func sameOutlineIsTrustedMoreInFittedClothes() {
        let fitted = engine.reconstruct(outline: 94, expected: waistPrior,
                                        coverPrior: ClothingAwareReconstruction.coverPrior(attire: .fitted, region: .waist))
        let everyday = engine.reconstruct(outline: 94, expected: waistPrior,
                                          coverPrior: ClothingAwareReconstruction.coverPrior(attire: .everyday, region: .waist))
        #expect(fitted.value.cm > everyday.value.cm)
        #expect(fitted.value.uncertaintyCm < everyday.value.uncertaintyCm)
    }

    @Test func noFixedAmountIsSubtracted() {
        // The correction depends on the outline and the body that's likely, not a constant.
        let prior = ClothingAwareReconstruction.coverPrior(attire: .everyday, region: .waist)
        let near = engine.reconstruct(outline: 86, expected: waistPrior, coverPrior: prior)
        let far = engine.reconstruct(outline: 100, expected: waistPrior, coverPrior: prior)
        let a = near.assessment.clothingEffectCm ?? 0, b = far.assessment.clothingEffectCm ?? 0
        #expect(abs(a - b) > 3)
    }

    @Test func looseTopFindingShiftsTheOdds() {
        let base = ClothingAwareReconstruction.coverPrior(attire: .fitted, region: .waist)
        let shifted = ClothingAwareReconstruction.applying([.looseTop], to: base, region: .waist)
        #expect(shifted[.loose]! > base[.loose]!)
        #expect(abs(shifted.values.reduce(0, +) - 1) < 1e-9)
        // Sleeves don't say anything about the waist.
        #expect(ClothingAwareReconstruction.applying([.looseSleeves], to: base, region: .waist) == base)
    }

    @Test func intervalsCoverTheTruthOnSimulatedClothedScans() {
        // Bodies from the statistics, clothes drawn from the same ease models: the 90%
        // intervals should hold the true waist about 90% of the time. This checks the
        // arithmetic, not the ease models themselves (that needs real paired scans).
        var rng = SplitMix(seed: 7)
        let prior = ClothingAwareReconstruction.coverPrior(attire: .everyday, region: .waist)
        var inside = 0, total = 0
        for _ in 0..<400 {
            let body = waistPrior.cm + waistPrior.uncertaintyCm * rng.gaussian()
            let cover = rng.pick(prior)
            let e = engine.ease[cover]!
            let outline = body * (1 + e.mean + e.sd * rng.gaussian()) * (1 + engine.outlineRelError * rng.gaussian())
            let r = engine.reconstruct(outline: outline, expected: waistPrior, coverPrior: prior)
            if r.assessment.low <= body && body <= r.assessment.high { inside += 1 }
            total += 1
        }
        let coverage = Double(inside) / Double(total)
        #expect((0.85...0.95).contains(coverage), "coverage \(coverage)")
    }

    @Test func profileGetsRegionalCoverAndAssessments() {
        var p = BodyProfile()
        p[.height] = MeasuredValue(cm: 173, uncertaintyCm: 1, source: .userProvided)
        p[.chest] = MeasuredValue(cm: 99, uncertaintyCm: 3, source: .scan)
        p[.waist] = MeasuredValue(cm: 95, uncertaintyCm: 2.8, source: .scan)
        p[.hip] = MeasuredValue(cm: 98, uncertaintyCm: 3, source: .scan)
        p[.armLength] = MeasuredValue(cm: 57, uncertaintyCm: 1.5, source: .scan)
        p.weightKg = 70
        let expected = AnthropometricPrior().estimate(heightCm: 173, weightKg: 70, sex: .male)
        let out = engine.apply(to: p, attire: .everyday, findings: [.looseTop], expected: expected)
        #expect(out.clothing?[.waist] ?? .skin > .fitted)
        #expect(out[.waist]!.cm < 95)
        #expect(out[.armLength] == p[.armLength])            // a length: untouched
        #expect(out.assessments?[.armLength] != nil)
        #expect(out.assessment(.waist)!.high > out.assessment(.waist)!.low)
    }

    @Test func earlierTightScanStandsInForTheStatistics() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var earlier = BodyProfile(createdAt: start, weightKg: 70, sex: .male)
        earlier[.waist] = MeasuredValue(cm: 80, uncertaintyCm: 1.5, source: .scan)
        earlier.clothing = [.waist: .fitted]
        earlier.assessments = [.waist: MeasurementAssessment(earlier[.waist]!)]
        let now = start.addingTimeInterval(2 * 30.4 * 86_400)
        let carried = ClothingAwareReconstruction.carriedForward(.waist, from: earlier, weightKg: 72, heightCm: 175, now: now)!
        #expect(carried.cm > 80.5 && carried.cm < 83)       // two kilos more
        #expect(carried.uncertaintyCm > 1.5 && carried.uncertaintyCm < 2)
        // An earlier scan in loose clothes is no reference.
        earlier.clothing = [.waist: .loose]
        #expect(ClothingAwareReconstruction.carriedForward(.waist, from: earlier, weightKg: 70, heightCm: 175, now: now) == nil)
        // Nor one from long ago.
        earlier.clothing = [.waist: .fitted]
        #expect(ClothingAwareReconstruction.carriedForward(.waist, from: earlier, weightKg: 70, heightCm: 175,
                                                           now: start.addingTimeInterval(3 * 365 * 86_400)) == nil)
    }

    @Test func detailGirthsAreEstimated() {
        let e = AnthropometricPrior().estimate(heightCm: 178, weightKg: 78, sex: .male)
        for d in BodyDimension.details { #expect(e[d] != nil, "\(d)") }
        #expect((36...44).contains(e[.neck]!.cm))
        #expect((14...19).contains(e[.wrist]!.cm))
        #expect((32...42).contains(e[.calf]!.cm))
    }
}

/// Deterministic random numbers for the simulated scans.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
    mutating func pick(_ odds: [ClothingCover: Double]) -> ClothingCover {
        var r = uniform() * odds.values.reduce(0, +)
        for cover in ClothingCover.allCases {
            r -= odds[cover] ?? 0
            if r <= 0 { return cover }
        }
        return .fitted
    }
}

@Suite struct ScanValidationTests {
    @Test func scoresPerGroupAndMeasurement() {
        let csv = """
        subject,group,dimension,scanned,low,high,tape
        a,fitted,waist,82,79,85,81
        a,fitted,waist,83,80,86,81
        b,fitted,waist,90,87,93,88
        a,tshirt,waist,85,78,92,81
        b,tshirt,waist,,,,88
        """
        let scores = ScanValidation.score(ScanValidation.records(csv: csv))
        let fitted = scores[.init(group: "fitted", dimension: .waist)]!
        #expect(fitted.count == 3)
        #expect(abs(fitted.meanAbsoluteError - 5.0 / 3) < 1e-9)
        #expect(abs(fitted.bias - 5.0 / 3) < 1e-9)
        #expect(fitted.repeatability == 1)
        #expect(fitted.coverage == 1)
        #expect(fitted.failureRate == 0)
        let tshirt = scores[.init(group: "tshirt", dimension: .waist)]!
        #expect(tshirt.failureRate == 0.5)
        #expect(tshirt.meanAbsoluteError == 4)
    }
}
