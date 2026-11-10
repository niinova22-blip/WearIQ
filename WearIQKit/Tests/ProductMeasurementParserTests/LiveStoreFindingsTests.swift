import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// What reading real store pages turned up (LivePageAudit, 2026-11-10), each kept as a
/// small case so it stays fixed.
@Suite struct LiveStoreFindingsTests {
    /// Amazon.com and Amazon.com.tr write jeans as "28W x 30L", "30W / 32L", "31-32".
    @Test func marketplaceWaistLengthLabels() {
        #expect(SizeLabel.waistLength("28W x 30L").map { [$0.waist, $0.length] } == [28, 30])
        #expect(SizeLabel.waistLength("30W / 32L").map { [$0.waist, $0.length] } == [30, 32])
        #expect(SizeLabel.waistLength("31-32").map { [$0.waist, $0.length] } == [31, 32])
        #expect(SizeLabel.waistLength("W31 L32").map { [$0.waist, $0.length] } == [31, 32])
        #expect(SizeLabel.waistOnly("30W Standart") == 30)
        #expect(SizeLabel.waistOnly("W34") == 34)
        #expect(SizeLabel.waistOnly("M") == nil)
        let chart = StandardSizeCharts.chart(for: ["30W x 32L", "32W x 32L", "34W x 32L"], category: .pants, audience: .men)
        #expect(chart?.sizes.count == 3)
        #expect(chart?.sizes.first?.values[.waist].map { Int($0.cm) } == 76)
    }

    /// Koton's menu links "%100 Pamuklu Ürünler"; the dress itself is "%10 Elastan, %90 Polyester".
    @Test func compositionIsTheProductsNotTheMenus() {
        let text = "Bebek | %100 Pamuklu Ürünler | Tayt\nKumaş: %10 Elastan, %90 Polyester\nKullanım Alanı: Özel Günler"
        let composition = FabricAdvice.compositionText(in: text)
        #expect(composition?.contains("Elastan") == true)
        #expect(GarmentClassifier.stretch(fromComposition: composition ?? "") == .high)
        #expect(FabricAdvice.compositionText(in: "%100 Pamuklu Ürünler") == nil)
    }

    /// Zara's structured data names fibres without shares.
    @Test func elastaneWithoutShareStillStretches() {
        #expect(GarmentClassifier.stretch(fromComposition: "polyester/viskoz/elastan") == .low)
        #expect(GarmentClassifier.stretch(fromComposition: "pamuk/polyester") == nil)
    }

    /// Tommy's chart: ranges are bodies, "Boyun" is the neck, "Kol 84-85" the back-to-wrist arm.
    @Test func rangedChartIsABodyChart() {
        let text = """
        Beden Ölçüsü XS S M L
        Göğüs 88-92 93-97 98-102 103-108
        Bel 78-82 83-87 88-92 93-98
        Kol 84-85 86-87 88-89 90-91
        Boyun 37-38 38-39 40-41 42-43
        """
        let chart = SizeChartParser().parse(text)
        #expect(chart.kind == .body)
        #expect(chart.sizes.allSatisfy { $0.values[.sleeveLength] == nil && $0.values[.bodyLength] == nil })
        #expect(chart.sizes.first?.values[.chest]?.cm == 90)
    }

    /// Hepsiburada and Koton list only the variant the page opened on: one size alone made
    /// that size the answer for every body.
    @Test func oneListedSizeUsesTheRegionsLadder() throws {
        var info = ProductInfo()
        info.name = "Erkek Regular Fit Tişört"
        info.category = .tshirt
        info.audience = .men
        info.availableSizes = ["S"]
        let (spec, source) = try #require(ProductSpec.make(from: info, region: .tr))
        #expect(source == .standard)
        #expect(spec.sizes.count >= 4)
    }

    /// Zara measures some stretch dresses 70 cm round the chest in XS: narrower than any
    /// XS woman. Such a chart is set aside for typical measurements of its sizes.
    @Test func implausiblyNarrowChartIsSetAside() throws {
        func size(_ label: String, _ chest: Double, _ waist: Double) -> SizeEntry {
            SizeEntry(label: label, values: [.chest: .manual(chest), .waist: .manual(waist)])
        }
        let narrow = ParsedSizeChart(sizes: [size("XS", 70, 66), size("S", 74, 70), size("M", 78, 74), size("L", 82, 78)],
                                     kind: .garment)
        #expect(StandardSizeCharts.implausiblyNarrow(narrow, category: .dress, audience: .women))
        let normal = ParsedSizeChart(sizes: [size("XS", 86, 70), size("S", 90, 74), size("M", 94, 78)], kind: .garment)
        #expect(!StandardSizeCharts.implausiblyNarrow(normal, category: .dress, audience: .women))

        var info = ProductInfo()
        info.name = "Hacimli Kollu Mini Elbise"
        info.category = .dress
        info.audience = .women
        info.availableSizes = ["XS", "S", "M", "L"]
        info.sizeChartSections = [SizeChartSection(title: nil, fitStyle: nil, chart: narrow)]
        let (_, source) = try #require(ProductSpec.make(from: info, region: .tr))
        #expect(source == .standard)
    }

    /// "Kloş" names a dress's skirt; the bodice is still fitted.
    @Test func skirtWordsDontLoosenADress() {
        #expect(GarmentClassifier.fitStyle(from: "Kloş Kesim Midi Elbise", category: .dress) == nil)
        #expect(GarmentClassifier.fitStyle(from: "Kloş Etek", category: .skirt) == .relaxed)
        #expect(GarmentClassifier.fitStyle(from: "Slim Fit Kloş Elbise", category: .dress) == .slim)
    }
}
