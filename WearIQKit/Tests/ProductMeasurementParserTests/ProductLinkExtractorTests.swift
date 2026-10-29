import Foundation
import Testing
@testable import ProductMeasurementParser

@Suite struct ProductLinkExtractorTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func recognisesStoreProductPages() {
        for s in [
            "https://www.trendyol.com/mavi/erkek-jean-p-123456789",
            "https://www.hepsiburada.com/koton-tisort-p-HBC00004ABCD12",
            "https://www.amazon.com.tr/dp/B0C1234567",
            "https://www.zara.com/tr/tr/basic-tisort-p01234567.html",
            "https://www.bershka.com/tr/oversize-sweatshirt-c0p123456789.html",
            "https://www2.hm.com/tr_tr/productpage.0970818001.html",
            "https://www.lcw.com/tr-TR/TR/urun/LC-WAIKIKI/erkek/Esofman-Alti/6990658/2961405",
            "https://www.defacto.com.tr/kirismaz-oversize-pamuklu-tisort-3171016",
        ] {
            #expect(ProductLinkExtractor.isProductURL(url(s)), "\(s)")
        }
    }

    @Test func leavesOutOtherPages() {
        for s in [
            "https://www.trendyol.com/sepet",
            "https://www.trendyol.com/erkek-t-shirt-x-g2-c73",
            "https://www.lcw.com/tr-TR/TR/hesabim/favorilerim",
            "https://www.defacto.com.tr/",
            "https://cdn.dsmcdn.com/ty123/product/media/images/1_org.jpg",
            "https://www.hepsiburada.com/yardim",
        ] {
            #expect(!ProductLinkExtractor.isProductURL(url(s)), "\(s)")
        }
    }

    @Test func basketPageGivesEachProductOnce() {
        let html = """
        <a href="/sepet">Sepetim</a>
        <a href="/mavi/erkek-jean-p-123456789?boutiqueId=61&merchantId=1">Mavi Jean</a>
        <a href="/mavi/erkek-jean-p-123456789?boutiqueId=61&amp;size=32">Mavi Jean</a>
        <a href='https://www.trendyol.com/koton/tisort-p-987654321'>Koton</a>
        <a href="/erkek-t-shirt-x-g2-c73">Tişört</a>
        """
        let links = ProductLinkExtractor.productLinks(html: html, pageURL: url("https://www.trendyol.com/sepet"))
        #expect(links.map(\.path) == ["/mavi/erkek-jean-p-123456789", "/koton/tisort-p-987654321"])
    }

    @Test func pastedLinks() {
        let text = """
        şunlara baktım:
        https://www.zara.com/tr/tr/basic-tisort-p01234567.html
        https://www.amazon.com.tr/dp/B0C1234567?th=1 ve bir de
        https://www.zara.com/tr/tr/basic-tisort-p01234567.html?v1=2
        """
        #expect(ProductLinkExtractor.productLinks(inText: text).count == 2)
    }
}
