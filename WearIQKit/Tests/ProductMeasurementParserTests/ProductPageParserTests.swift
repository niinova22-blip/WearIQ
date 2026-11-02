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

    @Test func categoriesFromTheName() {
        #expect(GarmentClassifier.category(from: "Kadın Yün Karışımlı Uzun Palto") == .coat)
        #expect(GarmentClassifier.category(from: "Kaşe Kaban") == .coat)
        #expect(GarmentClassifier.category(from: "Erkek Trençkot") == .coat)
        #expect(GarmentClassifier.category(from: "Slim Fit Blazer Ceket") == .jacket)
        #expect(GarmentClassifier.category(from: "Gömlek Elbise") == .dress)
        #expect(GarmentClassifier.category(from: "Midi Pileli Etek") == .skirt)
        #expect(GarmentClassifier.category(from: "Pamuklu Bluz") == .shirt)
        #expect(GarmentClassifier.category(from: "Men's Oxford Dress Shirt") == .shirt)
        #expect(GarmentClassifier.category(from: "Fitted dik yaka kazak") == .sweater)
        #expect(GarmentClassifier.category(from: "Kapüşonlu Sweatshirt") == .sweater)
        #expect(GarmentClassifier.category(from: "Crop Kazak") == .sweater)
        #expect(GarmentClassifier.category(from: "Basic Crop Top") == .tshirt)
        #expect(GarmentClassifier.category(from: "Denim Bermuda Şort") == .shorts)
        #expect(GarmentClassifier.category(from: "Kargo Pantolon") == .pants)
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

/// A trimmed excerpt of a real amazon.com.tr shirt page (no JSON-LD, no OpenGraph).
@Suite struct AmazonPageTests {
    @Test func readsAmazonProductPage() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/amazon_tr_shirt.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let info = ProductPageParser().parse(html: html, pageURL: URL(string: "https://www.amazon.com.tr/dp/B0776X8B3X"))
        #expect(info.name?.hasPrefix("Tommy Jeans TJM") == true)
        #expect(info.brand == "Tommy Jeans")
        #expect(info.imageURL?.absoluteString.contains("_AC_SL1500_") == true)
        #expect(info.availableSizes == ["XXS", "XS", "S", "M", "L", "XL", "XXL", "3XL"])
        #expect(info.category == .shirt)
        #expect(info.audience == .men)
        #expect(!info.isEmpty)
    }

    @Test func bylineForms() {
        #expect(AmazonPage.brand(fromByline: "Visit the Levi&#39;s Store") == "Levi's")
        #expect(AmazonPage.brand(fromByline: "Levi's Mağazasını ziyaret edin") == "Levi's")
    }
}

@Suite struct LegCutNames {
    @Test(arguments: [
        ("Erkek Skinny Fit Jean Pantolon", LegCut.skinny), ("Kadın Yüksek Bel Boru Paça Jean", .straight),
        ("Wide Leg Trousers", .wide), ("İspanyol Paça Kot Pantolon", .flare), ("Slim Straight Jeans", .straight),
        ("Jogger Eşofman Altı", .tapered), ("Slim Fit Chino", .slim), ("Geniş Paça Kumaş Pantolon", .wide),
        ("Mom Jean", .tapered), ("Bootcut Jeans", .flare),
    ])
    func names(_ name: String, _ cut: LegCut) {
        #expect(GarmentClassifier.legCut(from: name) == cut)
    }

    @Test func noCutInTheName() {
        #expect(GarmentClassifier.legCut(from: "Pamuklu Pantolon") == nil)
    }
}
