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
}
