import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

@Suite struct ProductPageParserTests {
    let parser = ProductPageParser()
    let url = URL(string: "https://shop.example.com/p/slim-fit-gomlek-123?utm_source=x#top")!

    @Test func readsProductJSONLDInsideGraph() {
        let html = """
        <html><head>
        <script type="application/ld+json">{"@context":"https://schema.org","@type":"BreadcrumbList"}</script>
        <script type='application/ld+json'>
        {"@context":"https://schema.org","@graph":[{"@type":"WebPage"},{
          "@type":"ProductGroup","name":"Slim Fit Oxford Gömlek","brand":{"@type":"Brand","name":"Example &amp; Co"},
          "image":["/img/1.jpg","/img/2.jpg"],"material":"%97 Pamuk %3 Elastan","category":"Erkek > Gömlek",
          "hasVariant":[{"@type":"Product","size":"S","gtin13":"8690000000017"},{"@type":"Product","size":"M"},{"@type":"Product","size":"M"}]
        }]}
        </script></head></html>
        """
        let info = parser.parse(html: html, pageURL: url)
        #expect(info.name == "Slim Fit Oxford Gömlek")
        #expect(info.brand == "Example & Co")
        #expect(info.imageURL?.absoluteString == "https://shop.example.com/img/1.jpg")
        #expect(info.availableSizes == ["S", "M"])
        #expect(info.gtin == "8690000000017")
        #expect(info.category == .shirt)
        #expect(info.fitStyle == .slim)
        #expect(info.stretch == .medium)
        #expect(info.productKey == "gtin:8690000000017")
    }

    @Test func readsSizesFromOffers() {
        let html = """
        <script type="application/ld+json">[{"@type":"Product","name":"Relaxed Jeans","brand":"Denim",
          "image":{"url":"https://cdn.example.com/j.jpg"},
          "offers":[{"@type":"Offer","itemOffered":{"size":"30/32"}},{"@type":"Offer","size":"32/32"}]}]</script>
        """
        let info = parser.parse(html: html, pageURL: url)
        #expect(info.brand == "Denim")
        #expect(info.availableSizes == ["30/32", "32/32"])
        #expect(info.category == .pants)
        #expect(info.fitStyle == .relaxed)
        #expect(info.imageURL?.host == "cdn.example.com")
        #expect(info.stretch == nil) // no composition published
    }

    @Test func readsPriceAndStockPerSize() {
        let html = #"""
        <script type="application/ld+json">{"@type":"ProductGroup","name":"Basic Tişört","hasVariant":[
          {"@type":"Product","size":"S","offers":{"@type":"Offer","price":"299.99","priceCurrency":"TRY","availability":"https://schema.org/InStock"}},
          {"@type":"Product","size":"M","offers":{"@type":"Offer","price":"299.99","priceCurrency":"TRY","availability":"https://schema.org/OutOfStock"}},
          {"@type":"Product","size":"L","offers":{"@type":"Offer","price":"1.249,90","priceCurrency":"TRY","availability":"http://schema.org/LimitedAvailability"}}
        ]}</script>
        """#
        let info = ProductPageParser().parse(html: html, pageURL: nil)
        #expect(info.price == 299.99)
        #expect(info.currency == "TRY")
        #expect(info.sizeStock == ["S": true, "M": false, "L": true])
    }

    @Test func fallsBackToOpenGraph() {
        let html = """
        <meta property="og:title" content="Basic Oversize T-Shirt">
        <meta content="https://cdn.example.com/t.jpg" property="og:image" />
        <meta property="product:brand" content="Brand">
        """
        let info = parser.parse(html: html, pageURL: url)
        #expect(info.name == "Basic Oversize T-Shirt")
        #expect(info.brand == "Brand")
        #expect(info.imageURL?.absoluteString == "https://cdn.example.com/t.jpg")
        #expect(info.category == .tshirt)
        #expect(info.fitStyle == .oversized)
        #expect(info.productKey == "url:https://shop.example.com/p/slim-fit-gomlek-123")
    }

    @Test func emptyPageYieldsEmptyInfo() {
        let info = parser.parse(html: "<html><body>Access denied</body></html>", pageURL: url)
        #expect(info.isEmpty)
        #expect(info.category == nil)
    }

    @Test func malformedJSONIsIgnored() {
        let html = #"<script type="application/ld+json">{"@type":"Product", broken</script><meta property="og:title" content="Ceket">"#
        let info = parser.parse(html: html, pageURL: nil)
        #expect(info.name == "Ceket")
        #expect(info.category == .jacket)
    }

    @Test func compositionStretch() {
        #expect(GarmentClassifier.stretch(fromComposition: "100% Cotton") == FabricStretch.none)
        #expect(GarmentClassifier.stretch(fromComposition: "98% cotton, 2% elastane") == .low)
        #expect(GarmentClassifier.stretch(fromComposition: "%92 Polyester %8 Elastan") == .high)
        #expect(GarmentClassifier.stretch(fromComposition: "Cotton blend") == nil)
    }

    @Test func embeddedStateGivesSizesAndChartImage() {
        // Shape of a marketplace page that renders from a JSON state blob.
        let html = #"""
        <script type="application/ld+json">{"@type":"Product","name":"Slim Fit Oxford Gömlek","brand":{"name":"Örnek"}}</script>
        <script>window.__STATE__={"sizeChartUrl":"https://cdn.example.com/charts/shirt.jpeg",
        "variants":[{"value":"S","beautifiedValue":"s","inStock":false},{"value":"M","inStock":true},{"value":"L"},{"value":"S"}],
        "price":{"value":"899"}}</script>
        """#
        let info = parser.parse(html: html, pageURL: url)
        #expect(info.availableSizes == ["S", "M", "L"])
        #expect(info.sizeChartImageURLs == [URL(string: "https://cdn.example.com/charts/shirt.jpeg")!])
        #expect(info.fitStyle == .slim)
    }

    @Test func sizeChartImgTag() {
        let html = #"<h1>Pantolon</h1><img class="x" src="/media/beden-tablosu/pantolon.png"><img src="/media/logo.png">"#
        let info = parser.parse(html: html, pageURL: url)
        #expect(info.sizeChartImageURLs.count == 1)
        #expect(info.sizeChartImageURLs.first?.path == "/media/beden-tablosu/pantolon.png")
    }
}
