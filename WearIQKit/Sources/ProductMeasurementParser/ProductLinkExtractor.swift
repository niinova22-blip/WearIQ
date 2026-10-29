import Foundation

/// Finds the product pages linked from a basket, wishlist or collection page, or in a
/// pasted block of text, so they can be analysed together.
///
/// Recognises the product URL shapes of common stores: Trendyol and Hepsiburada
/// ("…-p-123456"), Amazon ("/dp/ASIN"), Zara and the other Inditex brands
/// ("…-p01234567.html", "…-c0p123.html"), H&M ("productpage.0123.html"), LC Waikiki
/// ("/urun/"), and pages whose path ends in a long product number (DeFacto and many
/// others). Basket, account and help pages are left out.
public enum ProductLinkExtractor {
    public static let maximumLinks = 30

    private static let productPatterns = [
        #"-p-[0-9]{5,}"#, #"-p-[a-z0-9]{8,}"#,
        #"/dp/[a-z0-9]{10}"#, #"/gp/product/[a-z0-9]{10}"#,
        #"-p[0-9]{6,}\.html"#, #"c0p[0-9]+\.html"#,
        #"productpage\.[0-9]+\.html"#,
        #"/urun/"#, #"/product/"#, #"/products/"#,
        #"-[0-9]{6,}/?$"#, #"/[0-9]{7,}(\.html)?/?$"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let excluded = ["sepet", "cart", "basket", "checkout", "login", "giris", "uyelik", "account",
                                   "hesabim", "favori", "wishlist", "yardim", "help", "kampanya", "magaza"]

    public static func isProductURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return false }
        let path = url.path.lowercased()
        guard !path.isEmpty, path != "/" else { return false }
        if [".jpg", ".jpeg", ".png", ".webp", ".gif", ".svg", ".css", ".js"].contains(where: path.hasSuffix) { return false }
        let segments = path.split(separator: "/").map(String.init)
        if segments.contains(where: { segment in excluded.contains { segment == $0 || segment.hasPrefix($0 + "-") } }) { return false }
        let range = NSRange(path.startIndex..., in: path)
        return productPatterns.contains { $0.firstMatch(in: path, range: range) != nil }
    }

    /// Product links in a page's HTML, resolved against the page and in page order.
    public static func productLinks(html: String, pageURL: URL) -> [URL] {
        let pattern = try! NSRegularExpression(pattern: #"href\s*=\s*["']([^"'#\s]+)"#, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        let hrefs = pattern.matches(in: html, range: range).compactMap { match -> URL? in
            guard let r = Range(match.range(at: 1), in: html) else { return nil }
            let raw = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
            return URL(string: raw, relativeTo: pageURL)?.absoluteURL
        }
        return unique(hrefs.filter(isProductURL))
    }

    /// Product links in pasted text (several links, one per line or not).
    public static func productLinks(inText text: String) -> [URL] {
        let pattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive])
        let urls = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> URL? in
            guard let r = Range(match.range, in: text) else { return nil }
            // A sentence's full stop or comma isn't part of the link.
            return URL(string: String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)")))
        }
        return unique(urls.filter(isProductURL))
    }

    /// One link per product: the same page with other query parameters (colour, tracking)
    /// is the same product.
    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { continue }
            let key = (parts.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "") + parts.path.lowercased()
            guard seen.insert(key).inserted else { continue }
            parts.fragment = nil
            result.append(parts.url ?? url)
            if result.count == maximumLinks { break }
        }
        return result
    }
}
