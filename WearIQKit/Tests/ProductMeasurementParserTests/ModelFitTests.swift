import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

@Suite struct ModelFitTests {
    @Test func luxuryStoreWording() throws {
        let text = "Manken Ölçüleri Boy: 188 cm Göğüs: 100 cm - Bel: 84 cm - Kalça: 96 cm Mankenin üzerindeki ürün M bedendir. Yeni sezon hazır giyim"
        let fit = try #require(ModelFitParser.parse(text))
        #expect(fit.size == "M")
        #expect(fit.heightCm == 188)
        #expect(fit.chestCm == 100)
        #expect(fit.waistCm == 84)
        #expect(fit.hipCm == 96)
        #expect(fit.isAnchor)
    }

    @Test func marketplaceWording() throws {
        let text = "Mankenimiz 1.85 boyunda, göğüs ölçüsü 95 cm, bel ölçüsü 75 cm, basen ölçüsü 95 cm'dir. Mankenimiz üzerinde M beden ürün bulunmaktadır."
        let fit = try #require(ModelFitParser.parse(text))
        #expect(fit.chestCm == 95)
        #expect(fit.waistCm == 75)
        #expect(fit.hipCm == 95)
        #expect(fit.size == "M")
    }

    @Test func heightOnlyIsNotAnAnchor() throws {
        let fit = try #require(ModelFitParser.parse("Modelin boyu: 187 cm"))
        #expect(fit.heightCm == 187)
        #expect(!fit.isAnchor)
    }

    @Test func noModelMentionGivesNothing() {
        #expect(ModelFitParser.parse("Göğüs 95 cm olanlar için M beden önerilir.") == nil)
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
        let html = #"<h1>Siyah Dış Gömlek</h1><div class="model">Manken Ölçüleri: Göğüs: 98 cm - Bel: 79 cm - Kalça: 97 cm<br>Mankenin üzerindeki ürün L bedendir.</div><script>var x = "model bel 10";</script>"#
        let info = ProductPageParser().parse(html: html, pageURL: nil)
        #expect(info.modelFit?.size == "L")
        #expect(info.modelFit?.chestCm == 98)
    }
}
