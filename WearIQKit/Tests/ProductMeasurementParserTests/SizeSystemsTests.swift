import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// Pages that carry more than one size, and the size systems of Türkiye, Europe and the US.
@Suite struct MultiValuePageTests {
    /// Mavi's "Manken Bilgileri": two bodies first, then who wears what.
    static let maviModels = """
    Manken Bilgileri
    Boy: 179 cm, Göğüs: 85 cm, Bel: 60 cm, Kalça: 90 cm
    Boy: 189 cm, Göğüs: 90 cm, Bel: 73 cm, Kalça: 92 cm
    Kadın Manken: Jean: Bel: 26 / Boy: 30, Üst: S, Erkek Manken: Jean: Bel: 31 / Boy: 32, Üst: L
    Kumaş Bilgileri %100 Pamuk
    """

    @Test func menJeansTakeTheMansJeansSize() throws {
        let f = try #require(ModelFitParser.parse(Self.maviModels, audience: .men, category: .pants))
        #expect(f.size == "31/32")          // the jeans, not the T-shirt's L
        #expect(f.topSize == "L")
        #expect(f.audience == .men)
        #expect(f.heightCm == 189)          // the second body line is the man's
        #expect(f.chestCm == 90)
        #expect(f.waistCm == 73)
        #expect(f.hipCm == 92)
    }

    @Test func womenAndTopsTakeTheirOwn() throws {
        let woman = try #require(ModelFitParser.parse(Self.maviModels, audience: .women, category: .pants))
        #expect(woman.size == "26/30")
        #expect(woman.waistCm == 60)
        #expect(woman.heightCm == 179)
        let tee = try #require(ModelFitParser.parse(Self.maviModels, audience: .men, category: .tshirt))
        #expect(tee.size == "L")
    }

    @Test func twoModelsAndNoAudienceAnchorNothing() {
        // Either body would be wrong half the time.
        #expect(ModelFitParser.parse(Self.maviModels) == nil)
        #expect(ModelFitParser.parseAll(Self.maviModels).count == 2)
    }

    @Test func singleNamedModelStillCounts() throws {
        let f = try #require(ModelFitParser.parse("Erkek model 1.88 boyunda, göğüs 98, bel 82. Üzerindeki ürün M beden."))
        #expect(f.size == "M")
        #expect(f.chestCm == 98)
        #expect(f.audience == .men)
    }

    @Test func jeansSizeWrittenOtherWays() {
        #expect(ModelFitParser.bottomSize(in: "manken: jeans w30 l32, boy 185") == "30/32")
        #expect(ModelFitParser.bottomSize(in: "pantolon: 32x34") == "32/34")
        #expect(ModelFitParser.bottomSize(in: "etek: 38, ust: m") == "38")
        #expect(ModelFitParser.topSize(in: "etek: 38, ust: m") == "M")
    }

    @Test func nameAndDepartmentBeatTheDescription() {
        // Mavi's unisex wording names both: the store's "Erkek" department decides.
        let audience = GarmentClassifier.audience(in: [
            "90lar Classic Indigo Mavisi Jean Pantolon", "Anasayfa>Erkek>Jean>174",
            "MAVI 174, kadın ve erkeklerin kullanımına uygun unisex fit yapısıyla öne çıkar.",
        ])
        #expect(audience == .men)
        #expect(GarmentClassifier.audience(in: ["Kadın ve erkek için tişört", "/kadin/tisort"]) == .women)
        #expect(GarmentClassifier.audience(in: ["Unisex Hoodie", "Erkek"]) == nil)
        #expect(GarmentClassifier.audience(in: ["Men's Slim Jeans"]) == .men)
        #expect(GarmentClassifier.audience(in: ["Women's Mom Jeans"]) == .women)
    }

    /// The shape of Mavi's product page: JSON-LD WebPage → offers → itemOffered with every
    /// variant's barcode; the sizes in keyed rows of the Angular state, other products'
    /// rows too; a hidden Insider sheet with a T-shirt's letter sizes.
    static let maviPage = #"""
    <html><head><meta property="og:title" content="Erkek 90lar Classic Indigo Mavisi Jean Pantolon">
    <meta property="og:description" content="MAVI 174, kadın ve erkeklerin kullanımına uygun unisex fit yapısıyla öne çıkar.">
    <script type="application/ld+json">{"@context":"https://schema.org","@type":"WebPage","name":"90lar Classic Indigo Mavisi Jean Pantolon",
    "breadcrumb":{"@type":"BreadcrumbList","itemListElement":[{"@type":"ListItem","position":1,"item":{"@id":"https://www.mavi.com","name":"Anasayfa"}},{"@type":"ListItem","position":2,"item":{"@id":"https://www.mavi.com/erkek/c/2","name":"Erkek"}}]},
    "mainEntity":{"@type":"WebPageElement","offers":{"@type":"Offer","itemOffered":[{"@type":"Product","name":"90lar Classic Indigo Mavisi Jean Pantolon",
    "category":"Anasayfa&gt;Erkek&gt;Jean&gt;174","brand":{"@type":"Brand","name":"Mavi"},"sku":"0021201-A6388",
    "gtin13":["8685211217830","8685211217847","8685211217854"],
    "offers":{"@type":"Offer","price":"1649.99","priceCurrency":"TRY","availability":"https://schema.org/InStock"}}]}}}</script>
    </head><body>
    <script>window.state={"k":[["id","length","size","stockData","stockLevelStatus"],["code","name"]],"v":[
    [-7,"8685211217830","30","31",[-8,false,6,"~7"],"~7"],[-7,"8685211217847","32","31","~5","~6"],
    [-7,"8685211217854","32","32","~5","~6"],[-7,"9999999999999","28","44","~5","~6"]]}</script>
    <section class="ins-size-modal-wrapper ins-hidden"><div>Beden Seç</div><section class="ins-size-option">XS</section>
    <section class="ins-size-option">S</section><section class="ins-size-option">M</section><section class="ins-size-option">L</section></section>
    <div class="product-details-tab">Manken Bilgileri Boy: 179 cm, Göğüs: 85 cm, Bel: 60 cm, Kalça: 90 cm
    Boy: 189 cm, Göğüs: 90 cm, Bel: 73 cm, Kalça: 92 cm
    Kadın Manken: Jean: Bel: 26 / Boy: 30, Üst: S, Erkek Manken: Jean: Bel: 31 / Boy: 32, Üst: L
    Kumaş Bilgileri %100 Pamuk</div>
    </body></html>
    """#

    @Test func maviJeansPageReadsAsMenWaistAndLength() throws {
        let info = ProductPageParser().parse(html: Self.maviPage, pageURL: URL(string: "https://www.mavi.com/174-90lar/p/0021201-A6388"))
        #expect(info.category == .pants)
        #expect(info.audience == .men)
        #expect(info.brand == "Mavi")
        // Only the product's own variants, in W/L; never the hidden sheet's letters.
        #expect(info.availableSizes == ["31/30", "31/32", "32/32"])
        #expect(info.sizeSource == .variants)
        #expect(info.modelFit?.size == "31/32")
        #expect(info.modelFit?.audience == .men)
        #expect(info.modelFit?.waistCm == 73)
    }

    @Test func maviJeansGetAWaistAndLengthSize() throws {
        var info = ProductPageParser().parse(html: Self.maviPage, pageURL: nil)
        info.availableSizes = ["30/30", "30/32", "31/30", "31/32", "32/30", "32/32", "32/34", "33/32", "33/34", "34/32", "34/34", "36/32"]
        let (spec, source) = try #require(ProductSpec.make(from: info))
        #expect(source == .standard)
        #expect(spec.sizes.first?.label == "30/30")
        // Every size carries the inside leg its L is cut for.
        #expect(abs((spec.sizes.first { $0.label == "31/32" }?.values[.inseam]?.cm ?? 0) - 81.28) < 0.01)
        // The model's narrow 73 cm waist doesn't shift a chart of inch sizes.
        #expect(spec.sizes.first { $0.label == "31/32" }?.values[.waist]?.cm == 31 * 2.54)
    }

    @Test func jsonVariantsWithWaistAndLength() {
        let html = #"{"variants":[{"waist":"30","length":"32","sku":"a"},{"waist":"32","length":"32"},{"length":"34","waist":"32"}]}"#
        #expect(ProductPageParser.waistLengthVariants(in: html) == ["30/32", "32/32", "32/34"])
        // A single stray pair isn't a range of sizes.
        #expect(ProductPageParser.waistLengthVariants(in: #"{"size":"42","length":"30"}"#).isEmpty)
    }

    @Test func visibleSelectorsPickTheProductsSizes() {
        // Waist and length picked apart: joined into W/L.
        let wl = SizeOptions.labels(from: [
            .init(caption: "Bel", labels: ["30", "31", "32"]),
            .init(caption: "Boy", labels: ["30", "32"]),
        ], category: .pants)
        #expect(wl == ["30/30", "30/32", "31/30", "31/32", "32/30", "32/32"])
        // A quantity picker and a page list aren't sizes; the first real range wins.
        let tops = SizeOptions.labels(from: [
            .init(caption: "Adet", labels: ["1", "2", "3", "4"]),
            .init(caption: "", labels: ["1", "2", "3"]),
            .init(caption: "Beden", labels: ["S", "M", "L", "XL"]),
            .init(caption: "", labels: ["XS", "S"]),
        ], category: .tshirt)
        #expect(tops == ["S", "M", "L", "XL"])
        // US women's numbers are sizes.
        #expect(SizeOptions.labels(from: [.init(caption: "Size", labels: ["0", "2", "4", "6"])], category: .dress) == ["0", "2", "4", "6"])
    }

    @Test func sizeGuideWithTablesForTopsAndJeans() throws {
        func v(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .manual) }
        let tops = SizeChartSection(title: "Erkek Tişört", fitStyle: nil, chart: ParsedSizeChart(
            sizes: [SizeEntry(label: "M", values: [.chest: v(100), .waist: v(90)]), SizeEntry(label: "L", values: [.chest: v(106), .waist: v(96)])],
            kind: .garment, unit: .cm, warnings: []))
        let jeans = SizeChartSection(title: "Erkek Jean", fitStyle: nil, chart: ParsedSizeChart(
            sizes: [SizeEntry(label: "31/32", values: [.waist: v(80), .inseam: v(81)]), SizeEntry(label: "32/32", values: [.waist: v(82), .inseam: v(81)])],
            kind: .garment, unit: .cm, warnings: []))
        let women = SizeChartSection(title: "Kadın Jean", fitStyle: nil, chart: ParsedSizeChart(
            sizes: [SizeEntry(label: "26/30", values: [.waist: v(66), .inseam: v(76)]), SizeEntry(label: "27/30", values: [.waist: v(69), .inseam: v(76)])],
            kind: .garment, unit: .cm, warnings: []))
        #expect(SizeTableReader.best([tops, women, jeans], fit: nil, category: .pants, audience: .men) == jeans)
        #expect(SizeTableReader.best([jeans, tops], fit: nil, category: .tshirt, audience: .men) == tops)
        #expect(SizeTableReader.best([tops, women, jeans], fit: nil, category: .pants, audience: .women) == women)
    }

    @Test func waistLengthLabels() {
        #expect(SizeLabel.waistLength("31/32")! == (31, 32))
        #expect(SizeLabel.waistLength("W31 L32")! == (31, 32))
        #expect(SizeLabel.waistLength("w30/l34")! == (30, 34))
        #expect(SizeLabel.waistLength("32x30")! == (32, 30))
        #expect(SizeLabel.waistLength("M") == nil)
        #expect(SizeLabel.waistLength("38-40") == nil)
        #expect(SizeLabel.normalized("W31 L32") == "31/32")
        let sorted = SizeOrder.sorted(["32/30", "31/34", "31/30", "30/32", "31/32"].map { SizeEntry(label: $0, values: [:]) })
        #expect(sorted.map(\.label) == ["30/32", "31/30", "31/32", "31/34", "32/30"])
    }
}

@Suite struct SizeSystemTests {
    @Test func automaticRegionFollowsTheLanguage() {
        #expect(SizeRegion.automatic(language: "tr", region: "DE") == .tr)
        #expect(SizeRegion.automatic(language: "en", region: "TR") == .tr)
        #expect(SizeRegion.automatic(language: "en", region: "GB") == .eu)
        #expect(SizeRegion.automatic(language: "en", region: "US") == .us)
    }

    @Test func laddersPerRegion() {
        #expect(SizeSystems.ladder(for: .dress, audience: .women, region: .tr) == ["34", "36", "38", "40", "42", "44", "46"])
        #expect(SizeSystems.ladder(for: .dress, audience: .women, region: .us).prefix(3) == ["0", "2", "4"])
        #expect(SizeSystems.ladder(for: .tshirt, audience: .men, region: .us).contains("M"))
        let jeans = SizeSystems.ladder(for: .pants, audience: .men, region: .tr, productName: "Erkek Slim Jean")
        #expect(jeans.contains("32/32"))
        #expect(SizeSystems.ladder(for: .pants, audience: .men, region: .tr, productName: "Kumaş Pantolon").first == "44")
        #expect(SizeSystems.ladder(for: .pants, audience: .men, region: .us, productName: "Chino").contains("32/30"))
    }

    @Test func storeSizesInTheUsersSystem() {
        // A US store's women's 6 is a Turkish/European 38.
        #expect(SizeSystems.equivalent(of: "6", storeLabels: ["2", "4", "6", "8"], category: .dress, audience: .women, region: .tr) == "38")
        #expect(SizeSystems.equivalent(of: "38", storeLabels: ["36", "38", "40"], category: .dress, audience: .women, region: .us) == "6")
        // Same system: nothing to show.
        #expect(SizeSystems.equivalent(of: "M", storeLabels: ["S", "M", "L"], category: .tshirt, audience: .men, region: .tr) == nil)
        #expect(SizeSystems.equivalent(of: "31/32", storeLabels: ["31/32", "35/32"], category: .pants, audience: .men, region: .eu,
                                       productName: "jean") == nil)
        #expect(SizeSystems.equivalent(of: "38", storeLabels: ["36", "38"], category: .dress, audience: .women, region: .tr) == nil)
        // Men's waist-inch trousers in Türkiye's numbers.
        let tr = SizeSystems.equivalent(of: "32", storeLabels: ["30", "32", "34"], category: .pants, audience: .men, region: .tr,
                                        productName: "Chino Pantolon")
        #expect(["46", "48"].contains(tr ?? ""))
    }

    @Test func usWomensNumbersReadAsUsSizes() throws {
        let chart = try #require(StandardSizeCharts.chart(for: ["4", "6", "8"], category: .pants, audience: .women))
        // US 6 = EU 38: waist 70–74.
        #expect(chart.sizes.first { $0.label == "6" }?.values[.waist]?.cm == 72)
    }

    @Test func mensEuropeanTrousersAreNotInches() throws {
        let chart = try #require(StandardSizeCharts.chart(for: ["46", "48", "50"], category: .pants, audience: .men))
        // 48 is a waist of about 85 cm, not 122 (48 inches).
        let waist = try #require(chart.sizes.first { $0.label == "48" }?.values[.waist]?.cm)
        #expect((80...90).contains(waist))
    }
}
