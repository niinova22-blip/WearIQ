import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// What the on-device language model proposes from a page's prose, checked by rules.
@Suite struct TextMeasurementsTests {
    typealias P = TextMeasurements.Proposal

    let text = """
    Ürün ölçüleri: S beden ürünün beli 76 cm, iç boyu 78 cm. M beden ürünün beli 80 cm, iç boyu 79 cm. \
    L beden ürünün beli 84 cm, iç boyu 80 cm. Paça genişliği 17,5 cm. Manken 1.86 boyunda, 82 cm bel ölçüsüne sahip ve M beden giyiyor.
    """

    @Test func checkedProposalsMakeAChart() throws {
        let proposals = [
            P(size: "S", name: "beli", value: 76, unit: "cm", basis: "garment"),
            P(size: "S", name: "iç boyu", value: 78, unit: "cm", basis: "garment"),
            P(size: "M", name: "beli", value: 80, unit: "cm", basis: "garment"),
            P(size: "M", name: "iç boyu", value: 79, unit: "cm", basis: "garment"),
            P(size: "L", name: "beli", value: 84, unit: "cm", basis: "garment"),
            P(size: "L", name: "iç boyu", value: 80, unit: "cm", basis: "garment"),
            // The model's own waist: who wears the size, not the size.
            P(size: "M", name: "bel", value: 82, unit: "cm", basis: "model"),
        ]
        let chart = try #require(TextMeasurements.chart(from: proposals, text: text, sizes: ["S", "M", "L"]))
        #expect(chart.kind == .garment)
        #expect(chart.sizes.map(\.label) == ["S", "M", "L"])
        let m = try #require(chart.sizes.first { $0.label == "M" })
        #expect(m.values[.waist]?.cm == 80)
        #expect(m.values[.inseam]?.cm == 79)
    }

    /// A number the text doesn't hold, a name the dictionary doesn't know, a size the
    /// store doesn't sell: each is dropped on its own.
    @Test func inventedNumbersNamesAndSizesAreDropped() throws {
        let proposals = [
            P(size: "S", name: "beli", value: 76, unit: "cm", basis: "garment"),
            P(size: "M", name: "beli", value: 80, unit: "cm", basis: "garment"),
            P(size: "M", name: "iç boyu", value: 81, unit: "cm", basis: "garment"),   // not in the text
            P(size: "M", name: "kemer", value: 79, unit: "cm", basis: "garment"),     // not a measurement
            P(size: "XL", name: "beli", value: 84, unit: "cm", basis: "garment"),     // not sold
        ]
        let chart = try #require(TextMeasurements.chart(from: proposals, text: text, sizes: ["S", "M", "L"]))
        #expect(chart.sizes.map(\.label) == ["S", "M"])
        #expect(chart.sizes.allSatisfy { $0.values.keys.sorted { $0.rawValue < $1.rawValue } == [.waist] })
    }

    @Test func oneSizeAmongManyIsNoChart() {
        let proposals = [P(size: "M", name: "beli", value: 80, unit: "cm", basis: "garment")]
        #expect(TextMeasurements.chart(from: proposals, text: text, sizes: ["S", "M", "L"]) == nil)
    }

    @Test func numbersAreMatchedWhole() {
        #expect(TextMeasurements.appears(78, in: "iç boyu 78 cm"))
        #expect(!TextMeasurements.appears(78, in: "boy 178 cm"))
        #expect(!TextMeasurements.appears(78, in: "78,5 cm"))
        #expect(TextMeasurements.appears(17.5, in: "Paça genişliği 17,5 cm"))
        #expect(TextMeasurements.appears(17.5, in: "17.5cm"))
    }

    @Test func inchesOnlyWhenTheTextSaysInches() throws {
        let inchText = "Size 30: waist 30 inches, inseam 32 inches. Size 32: waist 32 inches, inseam 32 inches."
        let proposals = [
            P(size: "30", name: "waist", value: 30, unit: "inch", basis: "garment"),
            P(size: "32", name: "waist", value: 32, unit: "inch", basis: "garment"),
        ]
        let chart = try #require(TextMeasurements.chart(from: proposals, text: inchText, sizes: ["30", "32"]))
        #expect(abs((chart.sizes.first?.values[.waist]?.cm ?? 0) - 76.2) < 0.01)
        // "inch" from the model on a page in centimetres stays centimetres.
        let cmChart = TextMeasurements.chart(from: [
            P(size: "S", name: "beli", value: 76, unit: "inch", basis: "garment"),
            P(size: "M", name: "beli", value: 80, unit: "inch", basis: "garment"),
        ], text: text, sizes: ["S", "M", "L"])
        #expect(cmChart?.sizes.first?.values[.waist]?.cm == 76)
    }

    @Test func flatWidthsAreDoubled() throws {
        let flat = "Düz serim ölçüleri: S göğüs 52 cm, M göğüs 55 cm."
        let chart = try #require(TextMeasurements.chart(from: [
            P(size: "S", name: "göğüs", value: 52, unit: "cm", basis: "flat"),
            P(size: "M", name: "göğüs", value: 55, unit: "cm", basis: "flat"),
        ], text: flat, sizes: ["S", "M"]))
        #expect(chart.sizes.first?.values[.chest]?.cm == 104)
        #expect(chart.basis(for: .chest) == .flatLay)
    }

    @Test func theSentencesWorthReading() throws {
        let page = "Sepete ekle. Ücretsiz kargo 500 TL üzeri. M beden ürünün iç boyu 79 cm. Manken 1.86 boyunda."
        let picked = try #require(TextMeasurements.sentences(in: page))
        #expect(picked.contains("iç boyu 79 cm"))
        #expect(!picked.contains("kargo"))
    }
}
