import Foundation

/// Amazon product pages carry no JSON-LD or OpenGraph product data. The facts are in
/// the page itself: the title element, the brand byline ("Marka: Tommy Jeans", "Visit
/// the X Store"), the gallery's high-resolution image and the size swatches' JSON
/// ("size_name":["S","M",…]).
enum AmazonPage {
    static func isAmazon(_ html: String, url: URL?) -> Bool {
        if let host = url?.host?.lowercased(), host.contains("amazon.") || host.hasPrefix("amzn.") { return true }
        return html.contains("m.media-amazon.com") && html.contains("bylineInfo")
    }

    static func apply(_ html: String, to info: inout ProductInfo) {
        if info.name == nil {
            info.name = firstGroup(#"id="productTitle"[^>]*>([^<]+)<"#, in: html)
                ?? firstGroup(#"<h1[^>]*>\s*<span[^>]*id="title"[^>]*>([^<]+)<"#, in: html)
                ?? firstGroup(#"id="title"[^>]*>([^<]+)<"#, in: html)
                ?? firstGroup(#"<title>([^<]+?)\s*:\s*Amazon[^<]*</title>"#, in: html)
        }
        if info.brand == nil, let byline = firstGroup(#"id="bylineInfo"[^>]*>([^<]+)<"#, in: html) {
            info.brand = brand(fromByline: byline)
        }
        if info.imageURL == nil {
            let image = firstGroup(#""hiRes":"(https://[^"]+)""#, in: html)
                ?? firstGroup(#"data-old-hires="(https://[^"]+)""#, in: html)
                ?? firstGroup(#""landingImageUrl":"(https://[^"]+)""#, in: html)
            info.imageURL = image.flatMap(URL.init(string:))
        }
        if info.availableSizes.isEmpty, let list = firstGroup(#""size_name"\s*:\s*\[([^\]]*)\]"#, in: html) {
            info.availableSizes = list.split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
                .filter { !$0.isEmpty }
        }
    }

    /// "Marka: Tommy Jeans", "Brand: Levi's", "Visit the Levi's Store",
    /// "Levi's Mağazasını ziyaret edin" → the brand.
    static func brand(fromByline raw: String) -> String? {
        var s = ProductPageParser.decodeEntitiesForAmazon(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Marka:", "Brand:", "Visit the", "Marke:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        for suffix in ["Mağazasını ziyaret edin", "Store", "-Store"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func firstGroup(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let value = ProductPageParser.decodeEntitiesForAmazon(String(html[range]))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
