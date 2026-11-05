import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// What the Safari extension sends: the page's structured data and size tables, put
/// together as a small page.
@Suite struct ProductSpecTests {
    static let page = """
    <html><head><script type="application/ld+json">{"@context":"https://schema.org","@type":"Product",
    "name":"Erkek Slim Fit Basic Tişört","brand":{"@type":"Brand","name":"Koton"},
    "image":"https://example.com/p.jpg","offers":[{"@type":"Offer","price":"299.99","priceCurrency":"TRY","name":"S"},
    {"@type":"Offer","price":"299.99","priceCurrency":"TRY","name":"M"},{"@type":"Offer","price":"299.99","priceCurrency":"TRY","name":"L"}]}
    </script></head><body>
    <table><thead><tr><th></th><th>S</th><th>M</th><th>L</th></tr></thead>
    <tbody><tr><td>Boy</td><td>69</td><td>70</td><td>71</td></tr>
    <tr><td>Göğüs</td><td>50</td><td>53</td><td>56</td></tr></tbody></table>
    <p>%100 Pamuk</p></body></html>
    """

    @Test func storeTableBecomesASpec() throws {
        let info = ProductPageParser().parse(html: Self.page, pageURL: URL(string: "https://www.koton.com/p/1"))

        #expect(info.category == .tshirt)
        let (spec, source) = try #require(ProductSpec.make(from: info))
        #expect(source == .store)
        #expect(spec.fitStyle == .slim)
        #expect(spec.sizes.map(\.label) == ["S", "M", "L"])
        #expect(spec.sizes[1].values[.chest]?.cm == 106)
    }

    @Test func standardChartWithoutATable() throws {
        var info = ProductInfo()
        info.category = .tshirt
        info.availableSizes = ["S", "M", "L", "XL"]
        let (spec, source) = try #require(ProductSpec.make(from: info, fallbackAudience: .men))
        #expect(source == .standard)
        #expect(spec.chartKind == .body)
        #expect(spec.sizes.count == 4)
    }

    @Test func nothingWithoutAKindOfGarment() {
        var info = ProductInfo()
        info.availableSizes = ["S", "M"]
        #expect(ProductSpec.make(from: info) == nil)
    }

    /// LC Waikiki's "Boxy Fit Kalın Kumaş Tişört /05" was saved as shorts by an older
    /// build (a tester's avatar wore it as shorts): opening it again rebuilds it as a top.
    @Test func savedTeeReadAsShortsIsRepaired() throws {
        let name = "Boxy Fit Kalın Kumaş Tişört /05"
        #expect(GarmentClassifier.category(from: name) == .tshirt)
        #expect(GarmentClassifier.category(from: "Erkek > Erkek Giyim > Erkek Tişört " + name) == .tshirt)
        let shorts = GarmentSpec(category: .shorts, fitStyle: .oversized, stretch: .none, chartKind: .body,
                                 sizes: ["S", "M", "L", "XL", "2XL"].map { SizeEntry(label: $0, values: [.waist: MeasuredValue(cm: 80, uncertaintyCm: 1, source: .manual)]) },
                                 legCut: .wide)
        let fixed = try #require(ProductSpec.repaired(shorts, name: name, audience: .men))
        #expect(fixed.category == .tshirt)
        #expect(fixed.fitStyle == .oversized)
        #expect(fixed.legCut == nil)
        #expect(fixed.sizes.map(\.label) == ["S", "M", "L", "XL", "2XL"])
        #expect(fixed.sizes.allSatisfy { $0.values[.chest] != nil })
        // Nothing to fix: a top saved as a top, a name that says nothing.
        #expect(ProductSpec.repaired(fixed, name: name, audience: .men) == nil)
        #expect(ProductSpec.repaired(shorts, name: "Yeni sezon", audience: .men) == nil)
    }
}
