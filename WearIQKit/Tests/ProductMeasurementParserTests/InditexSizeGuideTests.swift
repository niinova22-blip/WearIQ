import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// Zara's men's jeans: sizes "EU 36 (US 29)" … and a size guide that only arrives as
/// JSON when the "Ürün boyutları" panel is opened (shape as zara.com/tr serves it).
@Suite struct InditexSizeGuideTests {
    static func measure(_ title: String, _ cm: Double) -> String {
        #"{"zoneId":"A","dimensions":[{"unitId":"cm","value":"\#(String(format: "%.1f", cm))"},{"unitId":"in","value":"0"}],"marketVariants":[],"tableTitle":"\#(title)","description":""}"#
    }

    static let guide: String = {
        let rows: [(String, Double, Double, Double, Double)] = [
            ("EU 36 (US 29)", 37, 48, 97, 29), ("EU 38 (US 30)", 39, 50, 98.5, 30), ("EU 40 (US 31)", 41, 52, 100, 31),
            ("EU 42 (US 32)", 43, 54, 101.5, 32), ("EU 44 (US 34)", 45, 56, 103, 33),
        ]
        let sizes = rows.map { r in
            #"{"id":"x","name":"\#(r.0)","labels":[],"measures":[\#(measure("BEL", r.1)),\#(measure("BASEN", r.2)),\#(measure("TOPLAM UZUNLUK", r.3)),\#(measure("ÖNDEN BEL YÜKSEKLİĞİ", r.4))]}"#
        }.joined(separator: ",")
        return #"{"sizeGuideInfo":null,"measureGuideInfo":{"id":"1","name":"SLIM CROPPED FIT JEAN","sizes":[\#(sizes)]},"activeByDefault":null}"#
    }()

    static let page = """
    <html><head><title>SLIM CROPPED FIT JEAN - LACİVERT | ZARA Türkiye / Turkey</title>
    <script type="application/ld+json">{"@context":"https://schema.org/","@type":"ProductGroup","name":"SLIM CROPPED FIT JEAN",
    "brand":{"@type":"Brand","name":"ZARA"},"description":"Modelin boyu: 185 cm\\n\\nKalçadan dize kadar oturan kesim.",
    "hasVariant":[{"@type":"Product","size":"EU 36 (US 29)","sku":"547493780-401-36","offers":{"price":2190,"priceCurrency":"TRY","availability":"https://schema.org/OutOfStock"}},
    {"@type":"Product","size":"EU 38 (US 30)","sku":"547493780-401-38","offers":{"price":2190,"priceCurrency":"TRY","availability":"https://schema.org/InStock"}},
    {"@type":"Product","size":"EU 40 (US 31)","sku":"547493780-401-40","offers":{"price":2190,"priceCurrency":"TRY","availability":"https://schema.org/InStock"}}]}</script>
    </head><body><script>window.zara={"locale":"tr_TR@TR","storeCode":"tr","storeCountryCode":"tr","storeId":11766,"x":{"storeId":"11716"}};
    window.dl={"catentryId":547493780,"section":"MAN","family":"PANTOLON"};</script></body></html>
    """

    @Test func guideAddressFromThePage() throws {
        let url = try #require(InditexSizeGuide.url(html: Self.page, pageURL: URL(string: "https://www.zara.com/tr/tr/slim-cropped-fit-jean-p04060302.html")!))
        #expect(url.absoluteString == "https://www.zara.com/itxrest/5/catalog/store/11766/product/547493780/size-measure-guide?locale=tr_TR")
        #expect(InditexSizeGuide.url(html: "<html>no ids</html>", pageURL: URL(string: "https://example.com/p/1")!) == nil)
    }

    @Test func garmentGuideIsReadFlatAndDoubled() throws {
        let chart = try #require(InditexSizeGuide.chart(from: Data(Self.guide.utf8), category: .pants))
        #expect(chart.kind == .garment)
        #expect(chart.sizes.map(\.label) == ["EU 36 (US 29)", "EU 38 (US 30)", "EU 40 (US 31)", "EU 42 (US 32)", "EU 44 (US 34)"])
        let first = chart.sizes[0]
        #expect(first.values[.waist]?.cm == 74)
        #expect(first.values[.hip]?.cm == 96)
        #expect(first.values[.outseam]?.cm == 97)
        // The rise ("Önden bel yüksekliği") is not the waist.
        #expect(first.values[.bodyLength] == nil)
    }

    @Test func zaraPageSizesKeepTheirUSWaist() {
        let info = ProductPageParser().parse(html: Self.page, pageURL: URL(string: "https://www.zara.com/tr/tr/slim-cropped-fit-jean-p04060302.html"))
        #expect(info.availableSizes == ["EU 36 (US 29)", "EU 38 (US 30)", "EU 40 (US 31)"])
        #expect(info.sizeStock["EU 38 (US 30)"] == true)
        #expect(info.audience == .men)
    }

    @Test func sizeLabelsWithAUSPart() {
        #expect(SizeLabel.withUS("EU 38 (US 30)")! == (38, 30))
        #expect(SizeLabel.withUS("36 (US 4)")! == (36, 4))
        #expect(SizeLabel.withUS("S (US S)") == nil)
        #expect(ProductPageParser.sizeLabel("S (US S)") == "S")
        #expect(ProductPageParser.sizeLabel("EU  38 (US 30)") == "EU 38 (US 30)")
        #expect(SizeLabel.standardReading("EU 38 (US 30)", category: .pants) == "W30")
        #expect(SizeLabel.standardReading("EU 36 (US 4)", category: .dress) == "36")
        #expect(SizeLabel.standardReading("EU 40", category: .pants) == "40")
    }

    /// Without a guide, "EU 38 (US 30)" jeans are a 30 in waist, not a European 38.
    @Test func standardChartReadsTheUSWaist() throws {
        let chart = try #require(StandardSizeCharts.chart(for: ["EU 36 (US 29)", "EU 38 (US 30)", "EU 40 (US 31)"],
                                                          category: .pants, audience: .men))
        #expect(chart.sizes.map(\.label) == ["EU 36 (US 29)", "EU 38 (US 30)", "EU 40 (US 31)"])
        let waist = try #require(chart.sizes[1].values[.waist]?.cm)
        #expect(abs(waist - 76.2) < 0.1)
    }
}
