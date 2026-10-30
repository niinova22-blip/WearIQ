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

private func shirt(_ sizes: [(String, Double, Double, Double, Double, Double)],
                   fit: FitStyle = .regular, stretch: FabricStretch = .none) -> GarmentSpec {
    GarmentSpec(category: .shirt, fitStyle: fit, stretch: stretch, chartKind: .garment, sizes: sizes.map {
        SizeEntry(label: $0.0, values: [.chest: m($0.1), .shoulderWidth: m($0.2), .sleeveLength: m($0.3),
                                        .bodyLength: m($0.4), .waist: m($0.5)])
    })
}

private let regularShirt = shirt([
    ("S", 104, 44, 63, 70, 96),
    ("M", 112, 46.5, 65.5, 73, 104),
    ("L", 120, 49, 68, 76, 112),
])

@Suite struct SizeComparison {
    @Test func recommendsSizeWithIdealChestAndShoulder() {
        let a = FitEngine().analyze(body: body, garment: regularShirt)
        guard case let .size(label, _) = a.recommendation else { Issue.record("\(a.recommendation)"); return }
        #expect(label == "M")
        let mFit = a.sizes[1]
        #expect(mFit.region(.chest)?.verdict == .ideal)
        #expect(mFit.region(.shoulder)?.verdict == .ideal)
        #expect(mFit.region(.sleeve)?.verdict == .ideal)
    }

    @Test func smallerSizeIsTightInChest() {
        let a = FitEngine().analyze(body: body, garment: regularShirt)
        let s = a.sizes[0]
        #expect(s.region(.chest)?.verdict == .tight) // ease 4 vs. min 9 → 5 cm short of room
        #expect(s.region(.chest)?.severity == .major)
        #expect(s.penalty > a.sizes[1].penalty)
    }

    @Test func largerSizeIsLooseAndSleeveLong() {
        let a = FitEngine().analyze(body: body, garment: shirt([("XL", 130, 52, 71, 79, 122)]))
        let xl = a.sizes[0]
        #expect(xl.region(.chest)?.verdict == .loose)
        #expect(xl.region(.sleeve)?.verdict == .long)
        let offset = try! #require(xl.region(.sleeve)?.estimatedOffsetCm)
        #expect(offset.contains(4)) // 71 - 63 = 8 ease, 4 over the 1...4 range
    }

    @Test func rankedPutsRecommendedFirst() {
        let a = FitEngine().analyze(body: body, garment: regularShirt)
        #expect(a.ranked.first?.label == "M")
    }

    @Test func closeNeighboursAreReportedAsBetweenSizes() {
        // Two sizes 1 cm apart in chest, both comfortably ideal → genuine tie.
        let g = shirt([("M", 112, 46, 65, 73, 104), ("M+", 113, 46.5, 65.5, 73.5, 105)])
        let a = FitEngine().analyze(body: body, garment: g)
        #expect(a.recommendation == .between(smaller: "M", larger: "M+"))
    }
}

@Suite struct TightAndLooseScenarios {
    @Test func stretchFabricMakesSnugSizeAcceptable() {
        let tightChest = shirt([("S", 98, 45, 63, 70, 92)], fit: .slim)
        let rigid = FitEngine().analyze(body: body, garment: tightChest).sizes[0].region(.chest)!
        let stretchy = FitEngine().analyze(body: body, garment: shirt([("S", 98, 45, 63, 70, 92)], fit: .slim, stretch: .high))
            .sizes[0].region(.chest)!
        #expect(rigid.verdict == .tight)
        #expect(stretchy.verdict == .ideal)
    }

    @Test func preferenceShiftsVerdict() {
        // Ease 16 sits at the top of the regular range.
        let g = shirt([("L", 116, 47, 65, 73, 104)])
        let snug = FitEngine().analyze(body: body, garment: g, preference: .snugger).sizes[0].region(.chest)!
        let loose = FitEngine().analyze(body: body, garment: g, preference: .looser).sizes[0].region(.chest)!
        #expect(snug.verdict == .slightlyLoose)
        #expect(loose.verdict == .ideal)
    }

    @Test func pantsWaistAndInseam() {
        let pants = GarmentSpec(category: .pants, chartKind: .garment, sizes: [
            SizeEntry(label: "32", values: [.waist: m(84), .hip: m(106), .thigh: m(64), .inseam: m(86)]),
            SizeEntry(label: "34", values: [.waist: m(88), .hip: m(110), .thigh: m(66), .inseam: m(86)]),
        ])
        let a = FitEngine().analyze(body: body, garment: pants)
        #expect(a.sizes[0].region(.waist)?.verdict == .slightlyTight)
        #expect(a.sizes[1].region(.waist)?.verdict == .ideal)
        #expect(a.sizes[1].region(.inseam)?.verdict == .long) // +5 vs. max +1
        #expect(a.recommendedSize?.label == "34")
    }
}

@Suite struct MissingData {
    @Test func noRecommendationWithoutCriticalGarmentData() {
        let g = GarmentSpec(category: .shirt, chartKind: .garment, sizes: [
            SizeEntry(label: "M", values: [.sleeveLength: m(65)]),
        ])
        let a = FitEngine().analyze(body: body, garment: g)
        #expect(a.recommendation == .insufficientData(missing: [.chest]))
        #expect(a.sizes[0].region(.chest)?.missing == .garmentMeasurement)
        #expect(a.sizes[0].region(.chest)?.severity == .unknown)
    }

    @Test func noRecommendationWithoutCriticalBodyData() {
        var b = body
        b[.chest] = nil
        let a = FitEngine().analyze(body: b, garment: regularShirt)
        guard case .insufficientData = a.recommendation else { Issue.record("expected insufficientData"); return }
        #expect(a.sizes[1].region(.chest)?.missing == .bodyMeasurement)
    }

    @Test func missingNonCriticalRegionsLowerConfidence() {
        let g = GarmentSpec(category: .shirt, chartKind: .garment, sizes: [
            SizeEntry(label: "M", values: [.chest: m(112)]),
        ])
        guard case let .size(_, confidence) = FitEngine().analyze(body: body, garment: g).recommendation else {
            Issue.record("expected size"); return
        }
        #expect(confidence == .low)
    }
}

@Suite struct Uncertainty {
    @Test func largeBodyUncertaintyLowersRegionConfidence() {
        var fuzzy = body
        fuzzy[.chest] = MeasuredValue(cm: 100, uncertaintyCm: 6, source: .scan)
        let precise = FitEngine().analyze(body: body, garment: regularShirt).sizes[1].region(.chest)!
        let unsure = FitEngine().analyze(body: fuzzy, garment: regularShirt).sizes[1].region(.chest)!
        #expect(precise.confidence == .high)
        #expect(unsure.confidence < precise.confidence)
        #expect(unsure.probabilityIdeal! < precise.probabilityIdeal!)
    }

    @Test func expectedPenaltyGrowsWithUncertaintyNearBoundary() {
        let rule = EaseTable.rules(for: .shirt, fit: .regular).first { $0.region == .chest }!
        let atEdge = FitEngine.expectedPenalty(ease: 9.5, sigma: 0, range: rule.ease, rule: rule)
        let fuzzy = FitEngine.expectedPenalty(ease: 9.5, sigma: 4, range: rule.ease, rule: rule)
        #expect(atEdge == 0)
        #expect(fuzzy > 0)
    }

    @Test func bodyChartUsesTolerance() {
        let g = GarmentSpec(category: .shirt, chartKind: .body, sizes: [
            SizeEntry(label: "M", values: [.chest: MeasuredValue(cm: 100, uncertaintyCm: 2, source: .manual)]),
            SizeEntry(label: "L", values: [.chest: MeasuredValue(cm: 108, uncertaintyCm: 2, source: .manual)]),
        ])
        let a = FitEngine().analyze(body: body, garment: g)
        #expect(a.sizes[0].region(.chest)?.verdict == .ideal)
        #expect(a.sizes[1].region(.chest)?.verdict == .slightlyLoose)
        #expect(a.recommendedSize?.label == "M")
    }
}

/// Trousers are sized by the waist: hips a few cm smaller than the size's are room.
@Suite struct TrouserHipRoomTests {
    @Test func hipRoomDoesNotBeatTheWaist() {
        // 173 cm man from the device scan: waist 83.5, hips 89.
        var body = BodyProfile()
        body[.waist] = MeasuredValue(cm: 83.5, uncertaintyCm: 3, source: .scan)
        body[.hip] = MeasuredValue(cm: 89, uncertaintyCm: 3, source: .scan)
        func size(_ label: String, waist: Double, hip: Double) -> SizeEntry {
            SizeEntry(label: label, values: [.waist: MeasuredValue(cm: waist, uncertaintyCm: 3, source: .manual),
                                             .hip: MeasuredValue(cm: hip, uncertaintyCm: 3, source: .manual)])
        }
        let spec = GarmentSpec(category: .pants, chartKind: .body,
                               sizes: [size("30", waist: 76.2, hip: 93), size("32", waist: 81.3, hip: 98), size("34", waist: 86.4, hip: 103)])
        let analysis = FitEngine().analyze(body: body, garment: spec)
        let s32 = analysis.sizes.first { $0.label == "32" }!
        let hip = s32.regions.first { $0.region == .hip }!
        #expect(hip.severity != .major)
        #expect(analysis.recommendedSize?.label == "32" || analysis.recommendation == .between(smaller: "32", larger: "34"))
    }
}

@Suite struct ScannedShoulders {
    /// A scan measures the straight distance between the shoulder bones; the chart's
    /// shoulder runs over the back. A 41.6 cm biacromial breadth is a 45 cm shoulder.
    @Test func scannedShoulderIsComparedOverTheBack() {
        var scanned = body
        scanned[.shoulderWidth] = MeasuredValue(cm: 41.6, uncertaintyCm: 1, source: .scan)
        let a = FitEngine().analyze(body: scanned, garment: regularShirt)
        let s = a.sizes[1].region(.shoulder)!
        #expect(s.verdict == .ideal)
        #expect(abs(s.easeCm! - (46.5 - 41.6 * 1.085)) < 0.01)
        // Typed in with a tape it is taken as it is.
        #expect(FitEngine.acrossBack(m(46)).cm == 46)
    }
}
