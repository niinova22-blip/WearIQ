import Testing
@testable import ShoppingAssistant
import ProductMeasurementParser
import WearIQCore

private func m(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .scan) }

/// A whole Mavi jeans page, as the Safari extension sends it: the product's own W/L
/// variants in script data, a hidden letter-size sheet (not sent: it isn't visible), the
/// model block with a woman's and a man's body and what each wears.
@Suite struct MultiSizePageTests {
    static let html = #"""
    <html><head><title>Erkek 90lar Classic Indigo Mavisi Jean Pantolon</title>
    <meta property="og:description" content="MAVI 174, kadın ve erkeklerin kullanımına uygun unisex fit yapısıyla öne çıkar.">
    <script type="application/ld+json">{"@type":"WebPage","mainEntity":{"@type":"WebPageElement","offers":{"@type":"Offer","itemOffered":[{"@type":"Product",
    "name":"90lar Classic Indigo Mavisi Jean Pantolon","category":"Anasayfa&gt;Erkek&gt;Jean&gt;174","brand":{"@type":"Brand","name":"Mavi"},
    "gtin13":["1","2","3","4","5","6","7","8","9"],"material":"%100 Pamuk"}]}}}</script></head><body>
    <script>{"k":[["id","length","size","stockData","stockLevelStatus"]],"v":[
    [-7,"1","30","31","~5","~6"],[-7,"2","32","31","~5","~6"],[-7,"3","32","32","~5","~6"],[-7,"4","34","32","~5","~6"],
    [-7,"5","32","33","~5","~6"],[-7,"6","34","33","~5","~6"],[-7,"7","32","34","~5","~6"],[-7,"8","34","34","~5","~6"],
    [-7,"9","32","36","~5","~6"],[-7,"99","32","29","~5","~6"]]}</script></body></html>
    """#

    static let text = """
    Manken Bilgileri
    Boy: 179 cm, Göğüs: 85 cm, Bel: 60 cm, Kalça: 90 cm
    Boy: 189 cm, Göğüs: 90 cm, Bel: 73 cm, Kalça: 92 cm
    Kadın Manken: Jean: Bel: 26 / Boy: 30, Üst: S, Erkek Manken: Jean: Bel: 31 / Boy: 32, Üst: L
    """

    @Test func maviJeansAreSizedByWaistAndLength() throws {
        let page = ShoppingAssistant.Page(url: "https://www.mavi.com/174-90lar/p/0021201-A6388", title: "Erkek 90lar Classic Indigo Mavisi Jean Pantolon",
                                          html: Self.html, text: Self.text, sizes: ["XS", "S", "M", "L"], sizeGroups: [])
        let info = ShoppingAssistant.product(page)
        #expect(info.audience == .men)
        #expect(info.availableSizes == ["31/30", "31/32", "32/32", "32/34", "33/32", "33/34", "34/32", "34/34", "36/32"])
        #expect(info.modelFit?.size == "31/32")

        // 173 cm man: waist 84, hip 100, inside leg 82.
        let body = BodyProfile(values: [.height: m(173), .chest: m(98), .waist: m(84), .hip: m(100), .inseam: m(82)], sex: .male)
        let advice = ShoppingAssistant.advise(page, shopper: .init(body: body, region: .tr))
        let size = try #require(advice.size)
        let wl = try #require(SizeLabel.waistLength(size), "a W/L size, not a letter: \(size)")
        #expect((32...34).contains(wl.waist))
        #expect(wl.length == 32)
    }
}
