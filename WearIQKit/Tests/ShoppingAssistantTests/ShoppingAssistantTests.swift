import Foundation
import Testing
@testable import ShoppingAssistant
import FitEngine
import WearIQCore

private func m(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .scan) }

private let shopper = ShoppingAssistant.Shopper(body: BodyProfile(values: [
    .height: m(178), .chest: m(98), .waist: m(84), .hip: m(98), .thigh: m(57), .shoulderWidth: m(45),
    .armLength: m(62), .torsoLength: m(47), .inseam: m(81), .outseam: m(106),
], sex: .male))

@Suite struct ShoppingAssistantTests {
    static let tee = """
    <script type="application/ld+json">{"@context":"https://schema.org","@type":"Product","name":"Erkek Regular Fit Tişört",
    "brand":{"@type":"Brand","name":"Koton"},"offers":{"@type":"Offer","price":"349.99","priceCurrency":"TRY"}}</script>
    <table><tr><th></th><th>S</th><th>M</th><th>L</th><th>XL</th></tr>
    <tr><td>Göğüs</td><td>51</td><td>54</td><td>57</td><td>60</td></tr>
    <tr><td>Boy</td><td>69</td><td>71</td><td>73</td><td>75</td></tr></table>
    """

    @Test func sizesATeeFromItsTable() {
        let page = ShoppingAssistant.Page(url: "https://www.koton.com/p/1", title: "Tişört", html: Self.tee,
                                          text: "Kumaş: %100 Pamuk. Model 1.86 boyunda ve M beden giyiyor.")
        let advice = ShoppingAssistant.advise(page, shopper: shopper)
        #expect(advice.category == .tshirt)
        #expect(advice.status == .sized || advice.status == .between)
        #expect(["M", "L"].contains(advice.size ?? ""))
        #expect(advice.brand == "Koton")
        #expect(advice.price == 349.99)
        #expect(!advice.fromStandardChart)
    }

    @Test func noTableUsesTheSizeButtons() {
        let page = ShoppingAssistant.Page(url: "https://www.zara.com/tr/p2", title: "Basic Gömlek", html: "<title>Basic Gömlek</title>",
                                          sizes: ["S", "M", "L", "XL"])
        let advice = ShoppingAssistant.advise(page, shopper: shopper)
        #expect(advice.category == .shirt)
        #expect(advice.fromStandardChart)
        #expect(advice.size != nil)
        // Typical measurements are never a sure answer.
        #expect((advice.risk ?? .low) >= .medium)
    }

    @Test func withoutMeasurementsItAsksForThem() {
        let page = ShoppingAssistant.Page(url: "https://x.com/p", html: Self.tee)
        #expect(ShoppingAssistant.advise(page, shopper: nil).status == .noBody)
    }

    @Test func notAGarment() {
        let page = ShoppingAssistant.Page(url: "https://x.com/p", title: "Kahve Makinesi", html: "<title>Kahve Makinesi</title>")
        #expect(ShoppingAssistant.advise(page, shopper: shopper).status == .notGarment)
    }

    @Test func swimwearIsFlagged() {
        let page = ShoppingAssistant.Page(url: "https://x.com/p", title: "Erkek Deniz Şortu", html: "<title>Erkek Deniz Şortu</title>",
                                          sizes: ["S", "M", "L"])
        let advice = ShoppingAssistant.advise(page, shopper: shopper)
        #expect(advice.nonReturnable)
    }

    @Test func styleSizeWhenConfirmed() {
        var style = StyleLearning.Style(topFit: .oversized, bottomFit: .regular)
        style.confirmed = true
        var withStyle = shopper
        withStyle.style = style
        let page = ShoppingAssistant.Page(url: "https://www.koton.com/p/1", html: Self.tee)
        let advice = ShoppingAssistant.advise(page, shopper: withStyle)
        if let size = advice.styleSize { #expect(size != advice.size) }
    }
}
