import Testing
@testable import FitEngine
import WearIQCore

private func m(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .manual) }

private let body = BodyProfile(values: [
    .height: m(170), .chest: m(92), .waist: m(74), .hip: m(98), .thigh: m(56), .calf: m(36),
    .shoulderWidth: m(38), .armLength: m(56), .inseam: m(78),
], sex: .female)

@Suite struct StyleLearningTests {
    /// Widths of an outline `room` wider than the body at each level.
    func observed(top: Double, seat: Double, thigh: Double, lower: Double) -> StyleLearning.Observation {
        StyleLearning.Observation(chest: 92 * 0.364 * (1 + top), waist: 74 * 0.355 * (1 + top), hip: 98 * 0.36 * (1 + seat),
                                  thigh: 56 * 0.318 * (1 + thigh), lowerLeg: 36 * 0.318 * (1 + lower))
    }

    @Test func oversizedTopOverSkinnyJeans() {
        let style = StyleLearning.infer(observed(top: 0.4, seat: 0.03, thigh: 0.03, lower: 0.05), body: body)
        #expect(style.topFit == .oversized)
        #expect(style.bottomFit == .slim)
        #expect(style.legCut == .skinny)
    }

    @Test func fittedTopOverWideTrousers() {
        let style = StyleLearning.infer(observed(top: 0.04, seat: 0.12, thigh: 0.35, lower: 0.9), body: body)
        #expect(style.topFit == .slim)
        #expect(style.legCut == .wide)
    }

    @Test func regularEverything() {
        let style = StyleLearning.infer(observed(top: 0.1, seat: 0.1, thigh: 0.15, lower: 0.25), body: body)
        #expect(style.topFit == .regular)
        #expect(style.legCut == .straight)
    }

    @Test func miniSkirt() {
        var o = observed(top: 0.1, seat: 0.12, thigh: 0, lower: 0)
        o.legsCovered = true; o.hemHeight = 0.38; o.thigh = nil; o.lowerLeg = nil
        let style = StyleLearning.infer(o, body: body)
        #expect(style.wearsSkirts)
        #expect(style.skirtLength == .mini)
    }

    @Test func sizeForARoomierStyle() {
        let tee = GarmentSpec(category: .tshirt, fitStyle: .regular, chartKind: .garment, sizes: [
            SizeEntry(label: "S", values: [.chest: m(96)]), SizeEntry(label: "M", values: [.chest: m(102)]),
            SizeEntry(label: "L", values: [.chest: m(110)]), SizeEntry(label: "XL", values: [.chest: m(118)]),
            SizeEntry(label: "XXL", values: [.chest: m(126)]),
        ])
        let analysis = FitEngine().analyze(body: body, garment: tee)
        var style = StyleLearning.Style(topFit: .oversized, bottomFit: .regular)
        #expect(StyleLearning.sizeForStyle(style, spec: tee, body: body, analysis: analysis) == nil, "not confirmed yet")
        style.confirmed = true
        let pick = StyleLearning.sizeForStyle(style, spec: tee, body: body, analysis: analysis)
        let order = ["S", "M", "L", "XL", "XXL"]
        #expect(pick != nil)
        if let pick, let rec = analysis.recommendedSize?.label {
            #expect(order.firstIndex(of: pick.size)! > order.firstIndex(of: rec)!)
            #expect(pick.fit == .oversized)
        }
    }
}
