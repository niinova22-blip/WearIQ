import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

@Suite struct ModelFitTests {
    private func fit(_ text: String) throws -> ModelFit { try #require(ModelFitParser.parse(text)) }

    @Test func compactTripletWithMetreHeight() throws {
        // As written on a large Turkish chain's product page.
        let f = try fit("Modelin Ölçüleri M Beden - 1,90cm - 100/84/101\nAna Kumaş İçeriği: : Akrilik 100%")
        #expect(f.size == "M")
        #expect(f.heightCm == 190)
        #expect(f.chestCm == 100)
        #expect(f.waistCm == 84)
        #expect(f.hipCm == 101)
        #expect(f.isAnchor)
    }

    @Test func labelledLuxuryWording() throws {
        let f = try fit("Manken Ölçüleri Boy: 188 cm Göğüs: 100 cm - Bel: 84 cm - Kalça: 96 cm Mankenin üzerindeki ürün M bedendir. Yeni sezon")
        #expect(f.size == "M")
        #expect(f.heightCm == 188)
        #expect(f.chestCm == 100)
        #expect(f.waistCm == 84)
        #expect(f.hipCm == 96)
    }

    @Test func marketplaceSentence() throws {
        let f = try fit("Mankenimiz 1.85 boyunda, göğüs ölçüsü 95 cm, bel ölçüsü 75 cm, basen ölçüsü 95 cm'dir. Mankenimiz üzerinde M beden ürün bulunmaktadır.")
        #expect(f.heightCm == 185)
        #expect(f.chestCm == 95)
        #expect(f.waistCm == 75)
        #expect(f.hipCm == 95)
        #expect(f.size == "M")
    }

    @Test func dashTripletAndBedenFirst() throws {
        let f = try fit("Model: 187 cm, 92-76-98, beden L")
        #expect(f.heightCm == 187)
        #expect(f.chestCm == 92)
        #expect(f.waistCm == 76)
        #expect(f.hipCm == 98)
        #expect(f.size == "L")
    }

    @Test func englishFeetAndInches() throws {
        let f = try fit("The model is 6'1\" and wears a size M. Chest 38\", waist 31\"")
        #expect(f.heightCm == 185)
        #expect(f.size == "M")
        #expect(abs((f.chestCm ?? 0) - 96.5) < 0.1)
        #expect(abs((f.waistCm ?? 0) - 78.7) < 0.1)
    }

    @Test func womensWording() throws {
        let f = try fit("Manken bilgileri: Boy 1.76 m, Göğüs 84, Bel 62, Basen 90. Mankenin bedeni: S")
        #expect(f.heightCm == 176)
        #expect(f.chestCm == 84)
        #expect(f.waistCm == 62)
        #expect(f.hipCm == 90)
        #expect(f.size == "S")
    }

    @Test func numericSizeOnModel() throws {
        let f = try fit("modelin bedeni: 36 Boyu: 181 cm.")
        #expect(f.size == "36")
        #expect(f.heightCm == 181)
        #expect(!f.isAnchor)
    }

    @Test func heightOnlyIsNotAnAnchor() throws {
        let f = try fit("Modelin boyu: 187 cm")
        #expect(f.heightCm == 187)
        #expect(!f.isAnchor)
    }

    @Test func noModelMentionGivesNothing() {
        #expect(ModelFitParser.parse("Göğüs 95 cm olanlar için M beden önerilir.") == nil)
    }

    @Test func priceAndDatesAreNotMeasurements() throws {
        let f = try fit("Model 2026/10/28 tarihinde eklendi. Fiyat 1.999,95 TL. Model M beden giyiyor.")
        #expect(f.size == "M")
        #expect(f.chestCm == nil)
        #expect(f.heightCm == nil)
    }

    @Test func standardChartShiftsToTheModel() throws {
        let anchor = ModelFit(size: "M", heightCm: 188, chestCm: 96, waistCm: 82, hipCm: nil)
        let chart = try #require(StandardSizeCharts.chart(for: ["S", "M", "L"], category: .shirt, audience: .men, anchor: anchor))
        let m = try #require(chart.sizes.first { $0.label == "M" })
        #expect(m.values[.chest]?.cm == 96)        // standard 100, model 96
        #expect(m.values[.waist]?.cm == 82)
        #expect(chart.sizes.first { $0.label == "L" }?.values[.chest]?.cm == 104)
        #expect(chart.warnings.contains(.anchoredToModel(size: "M")))
    }

    @Test func pageParserFindsModelFit() {
        let html = #"<h1>Polo Yaka Basic Kazak</h1><div class="model">Modelin Ölçüleri <b>M Beden</b> - 1,90cm - 100/84/101</div><script>var x = "model bel 10";</script>"#
        let info = ProductPageParser().parse(html: html, pageURL: nil)
        #expect(info.modelFit?.size == "M")
        #expect(info.modelFit?.hipCm == 101)
    }
}
