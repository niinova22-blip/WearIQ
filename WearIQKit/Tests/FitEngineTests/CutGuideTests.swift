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

@Suite struct CutGuideTests {
    /// An oversized tee charted by garment measurements: the size whose room is the cut's
    /// is recommended; a size down is the subtler look; a regular fit is 109–116 round.
    @Test func oversizedTee() throws {
        let spec = GarmentSpec(category: .tshirt, fitStyle: .oversized, chartKind: .garment, sizes: [
            SizeEntry(label: "S", values: [.chest: m(118), .shoulderWidth: m(54), .bodyLength: m(70)]),
            SizeEntry(label: "M", values: [.chest: m(126), .shoulderWidth: m(57), .bodyLength: m(72)]),
            SizeEntry(label: "L", values: [.chest: m(134), .shoulderWidth: m(60), .bodyLength: m(74)]),
        ])
        let analysis = FitEngine().analyze(body: body, garment: spec)
        let note = try #require(CutGuide.note(for: spec, body: body, analysis: analysis))
        #expect(note.cut == .oversizedTop)
        #expect(note.size == analysis.recommendedSize?.label)
        #expect(note.alternativeChestCm == 109...116)
        #expect((note.shoulderDropCm ?? 0) > 2)
        if note.size == "M" { #expect(note.subtlerSize == "S") }
    }

    @Test func regularTopNeedsNoNote() {
        let spec = GarmentSpec(category: .shirt, chartKind: .garment, sizes: [
            SizeEntry(label: "M", values: [.chest: m(112)]),
        ])
        #expect(CutGuide.note(for: spec, body: body, analysis: FitEngine().analyze(body: body, garment: spec)) == nil)
    }

    /// Skinny jeans: their thighs are judged as skinny ones (close is right), and the
    /// note points those who don't want that to a straight leg's thigh.
    @Test func skinnyJeans() throws {
        let sizes = [
            SizeEntry(label: "32", values: [.waist: m(87), .hip: m(102), .thigh: m(60), .inseam: m(81)]),
        ]
        let skinny = GarmentSpec(category: .pants, fitStyle: .slim, stretch: .low, chartKind: .garment, sizes: sizes, legCut: .skinny)
        let plain = GarmentSpec(category: .pants, fitStyle: .regular, stretch: .low, chartKind: .garment, sizes: sizes)
        let a = FitEngine().analyze(body: body, garment: skinny)
        let b = FitEngine().analyze(body: body, garment: plain)
        #expect(a.sizes[0].region(.thigh)?.verdict == .ideal)
        #expect(b.sizes[0].region(.thigh)?.verdict != .ideal)
        let note = try #require(CutGuide.note(for: skinny, body: body, analysis: a))
        #expect(note.cut == .skinnyLeg)
        #expect(note.alternativeThighCm == 64...70)
        #expect(!note.rigidSkinny)
    }

    /// Wide legs: a lot of thigh room is the cut, not a size too big.
    @Test func wideLegThighIsTheCut() {
        let sizes = [SizeEntry(label: "M", values: [.waist: m(87), .hip: m(114), .thigh: m(78)])]
        let wide = GarmentSpec(category: .pants, fitStyle: .relaxed, chartKind: .garment, sizes: sizes, legCut: .wide)
        let a = FitEngine().analyze(body: body, garment: wide)
        #expect(a.sizes[0].region(.thigh)?.verdict == .ideal)
        #expect(CutGuide.note(for: wide, body: body, analysis: a)?.cut == .wideLeg)
    }
}
