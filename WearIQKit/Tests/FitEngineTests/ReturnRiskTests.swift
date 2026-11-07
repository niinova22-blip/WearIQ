import Testing
@testable import FitEngine
import WearIQCore

private func m(_ cm: Double, _ u: Double = 0.5) -> MeasuredValue {
    MeasuredValue(cm: cm, uncertaintyCm: u, source: .manual)
}

private let body = BodyProfile(values: [
    .height: m(178), .shoulderWidth: m(46), .armLength: m(63), .chest: m(100),
    .waist: m(86), .torsoLength: m(48), .hip: m(100), .thigh: m(58), .inseam: m(81), .outseam: m(106),
])

private let tee = GarmentSpec(category: .tshirt, fitStyle: .regular, chartKind: .garment, sizes: [
    SizeEntry(label: "S", values: [.chest: m(100), .bodyLength: m(68)]),
    SizeEntry(label: "M", values: [.chest: m(108), .bodyLength: m(70)]),
    SizeEntry(label: "L", values: [.chest: m(116), .bodyLength: m(72)]),
    SizeEntry(label: "XL", values: [.chest: m(124), .bodyLength: m(74)]),
])

@Suite struct ReturnRiskTests {
    @Test func sureFitIsLowRisk() {
        let analysis = FitEngine().analyze(body: body, garment: tee)
        let risk = ReturnRisk.assess(analysis, category: .tshirt, productName: "Basic tişört")
        if case .size(_, .high) = analysis.recommendation {
            #expect(risk.level == .low)
            #expect(risk.reasons.isEmpty)
        } else {
            #expect(risk.level >= .medium)
        }
        #expect(!risk.nonReturnable)
    }

    @Test func noSizeFitsIsHighRisk() {
        var big = body
        big[.chest] = m(140)
        let analysis = FitEngine().analyze(body: big, garment: tee)
        let risk = ReturnRisk.assess(analysis, category: .tshirt, productName: nil)
        #expect(risk.level == .high)
        #expect(risk.reasons.contains(.noSizeFits) || risk.reasons.contains(.criticalRegionOff))
    }

    @Test func estimatesAreNeverLowRisk() {
        let analysis = FitEngine().analyze(body: BodyProfile(values: [
            .height: m(178), .chest: MeasuredValue(cm: 100, uncertaintyCm: 4, source: .estimated),
        ]), garment: tee)
        let risk = ReturnRisk.assess(analysis, category: .tshirt, productName: nil)
        #expect(risk.level >= .medium)
        #expect(risk.reasons.contains(.fromEstimates))
    }

    /// A scan's waist is good to about ±4 cm (90%: 76–90 cm) and jeans come in 2.5 cm
    /// steps, so the advice is rarely sure. That alone isn't a likely return: every pair of
    /// jeans and most tops were "high risk" for a scanned shopper.
    @Test(arguments: stride(from: 76.0, through: 96.0, by: 1.0).map { $0 })
    func scanDoubtAloneIsNotHighRisk(waist: Double) {
        func s(_ cm: Double, _ u: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: u, source: .scan) }
        let scanned = BodyProfile(values: [.height: s(178, 1), .waist: s(waist, 4.3), .hip: s(waist + 14, 3),
                                           .inseam: s(81, 2.5), .thigh: s(58, 3), .outseam: s(106, 2.5)])
        let jeans = GarmentSpec(category: .pants, fitStyle: .regular, chartKind: .garment, sizes: (28...40).map { w in
            SizeEntry(label: "\(w)/32", values: [.waist: m(Double(w) * 2.54 + 2), .hip: m(Double(w) * 2.54 + 20),
                                                  .inseam: m(81)])
        })
        let analysis = FitEngine().analyze(body: scanned, garment: jeans)
        let risk = ReturnRisk.assess(analysis, category: .pants, productName: "Slim Fit Jean")
        #expect(analysis.noSizeFits == nil)
        #expect(risk.level <= .medium, "waist \(waist): \(analysis.recommendation) \(risk.reasons)")
    }

    /// Doubt and a size that's likely off together are still a high risk.
    @Test func doubtOverAClearlyOffSizeIsHighRisk() {
        func s(_ cm: Double, _ u: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: u, source: .scan) }
        let scanned = BodyProfile(values: [.height: s(178, 1), .chest: s(100, 6)])
        let analysis = FitEngine().analyze(body: scanned, garment: tee)
        let risk = ReturnRisk.assess(analysis, size: "XL", category: .tshirt, productName: nil)
        #expect(risk.level == .high)
    }

    @Test func missingChartIsHighRisk() {
        let analysis = FitAnalysis(recommendation: .insufficientData(missing: [.chest]), sizes: [])
        #expect(ReturnRisk.assess(analysis, category: .tshirt, productName: nil).level == .high)
    }

    @Test func choosingAnotherSizeJudgesThatSize() {
        let analysis = FitEngine().analyze(body: body, garment: tee)
        let risk = ReturnRisk.assess(analysis, size: "XL", category: .tshirt, productName: nil)
        #expect(risk.level >= .medium)
        #expect(risk.reasons.contains(.criticalRegionOff))
    }

    @Test func hygieneItemsTurnDoubtIntoHighRisk() {
        let between = FitAnalysis(recommendation: .between(smaller: "M", larger: "L"), sizes: [])
        let swim = ReturnRisk.assess(between, category: .shorts, productName: "Erkek Deniz Şortu")
        #expect(swim.nonReturnable)
        #expect(swim.level == .high)
        let plain = ReturnRisk.assess(between, category: .shorts, productName: "Erkek Bermuda Şort")
        #expect(!plain.nonReturnable)
        #expect(plain.level == .medium)
    }

    @Test(arguments: [
        ("Kadın Bikini Takımı", true), ("Yüksek Bel Mayo", true), ("Pamuklu Külot 3'lü", true),
        ("Erkek Boxer", true), ("Dantelli Sütyen", true), ("İç Çamaşırı Seti", true),
        ("Women's Swimsuit", true), ("Lace Bralette", true), ("Seamless Briefs", true),
        ("Saten Slip Elbise", false), ("Oversize Tişört", false), ("Slim Fit Kot Pantolon", false),
        ("Brave Soul Hoodie", false), ("Tankini", true), ("Abrasive", false),
    ])
    func hygieneWords(name: String, expected: Bool) {
        #expect(NonReturnable.isHygieneItem(name: name) == expected)
    }
}

@Suite struct FitOutcomeTests {
    @Test func countsOnlyWhatWasReported() {
        let summary = FitOutcomeSummary([
            PurchaseOutcome(recommended: "M", taken: "M", usual: "L", fit: .right),
            PurchaseOutcome(recommended: "M", taken: "m", usual: "M", fit: .right),
            PurchaseOutcome(recommended: "L", taken: "L", fit: .tight),
            PurchaseOutcome(recommended: "L", taken: "M", usual: "M", fit: .right),
            PurchaseOutcome(recommended: "S", taken: "S", fit: nil),
            PurchaseOutcome(recommended: "S", taken: "S", usual: "M", fit: .right, returned: true),
        ])
        #expect(summary.rated == 5)
        #expect(summary.pending == 1)
        #expect(summary.followedAdvice == 4)
        #expect(summary.adviceFitFirstTime == 2)
        // Only the first: the usual size differed and WearIQ's fit and was kept.
        #expect(summary.likelyReturnsAvoided == 1)
        #expect(summary.adviceHitRate == 0.5)
    }

    @Test func tooFewAnswersGiveNoRate() {
        let summary = FitOutcomeSummary([PurchaseOutcome(recommended: "M", taken: "M", fit: .right)])
        #expect(summary.adviceHitRate == nil)
    }
}

@Suite struct ReferenceGarmentTests {
    @Test func closestSizeToAFavouriteTee() throws {
        let match = try #require(ReferenceGarment.closest(spec: tee, reference: [.chest: 110, .bodyLength: 71]))
        #expect(match.size == "M")
        #expect(match.differences[.chest] == -2)
    }

    @Test func nothingCloseEnough() {
        #expect(ReferenceGarment.closest(spec: tee, reference: [.chest: 150]) == nil)
    }

    @Test func bodyChartsDoNotCompare() {
        var bodyChart = tee
        bodyChart.chartKind = .body
        #expect(ReferenceGarment.matches(spec: bodyChart, reference: [.chest: 108]).isEmpty)
    }

    @Test func lengthsAloneDoNotCompare() {
        #expect(ReferenceGarment.matches(spec: tee, reference: [.bodyLength: 70]).isEmpty)
    }
}
