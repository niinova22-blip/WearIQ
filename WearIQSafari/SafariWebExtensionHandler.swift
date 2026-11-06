import Foundation
import SafariServices
import ProductMeasurementParser
import ShoppingAssistant

/// The Safari extension's native side. The content script, on a product page of a store
/// the user allowed, sends the page's useful parts; this sizes the garment for the user
/// (from the body the app left in the shared keychain), answers with the advice the page
/// shows as a small badge, and leaves the product for the app's shopping memory. All on
/// the phone; nothing is sent anywhere.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        var reply: [String: Any] = ["status": "error"]
        if let message, message["type"] as? String == "product",
           let url = message["url"] as? String, let html = message["html"] as? String {
            let page = ShoppingAssistant.Page(url: url, title: message["title"] as? String, html: String(html.prefix(400_000)),
                                              text: (message["text"] as? String).map { String($0.prefix(4000)) },
                                              sizes: message["sizes"] as? [String],
                                              sizeGroups: (message["sizeGroups"] as? [[String: Any]]).map(Self.groups))
            let advice = ShoppingAssistant.advise(page, shopper: ShoppingBridge.shopper())
            if advice.status != .notGarment {
                ShoppingBridge.enqueue(.init(page: page, advice: advice, seenAt: Date()))
            }
            reply = Self.reply(advice)
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// The visible size selectors the content script found, with their captions.
    static func groups(_ raw: [[String: Any]]) -> [SizeOptionGroup] {
        raw.prefix(10).compactMap { g in
            guard let labels = g["labels"] as? [String] else { return nil }
            return SizeOptionGroup(caption: String((g["caption"] as? String ?? "").prefix(40)), labels: Array(labels.prefix(60)))
        }
    }

    static func reply(_ a: ShoppingAssistant.Advice) -> [String: Any] {
        var r: [String: Any] = ["status": a.status.rawValue]
        if let size = a.size { r["size"] = size }
        if let other = a.otherSize { r["otherSize"] = other }
        if let risk = a.risk { r["risk"] = risk.rawValue }
        if let style = a.styleSize { r["styleSize"] = style }
        if let confidence = a.confidence { r["confidence"] = confidence.rawValue }
        r["nonReturnable"] = a.nonReturnable
        r["standard"] = a.fromStandardChart
        return r
    }
}
