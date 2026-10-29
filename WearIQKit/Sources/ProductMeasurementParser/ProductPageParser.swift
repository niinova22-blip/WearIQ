import Foundation
import WearIQCore

/// What could be read from a product page. Every field is optional because stores
/// publish very different amounts of structured data; nothing is invented.
public struct ProductInfo: Equatable, Sendable {
    public var name: String?
    public var brand: String?
    public var imageURL: URL?
    public var pageURL: URL?
    public var gtin: String?
    public var sku: String?
    public var categoryText: String?
    public var material: String?
    /// Size labels offered by the store, in page order, de-duplicated.
    public var availableSizes: [String] = []
    /// Size chart images the store links from the page (read with on-device OCR).
    public var sizeChartImageURLs: [URL] = []
    /// Size charts published as HTML tables in the page itself.
    public var sizeChartSections: [SizeChartSection] = []

    /// Inferred from name/category; `nil` when the text doesn't say.
    public var category: GarmentCategory?
    public var fitStyle: FitStyle?
    public var stretch: FabricStretch?
    public var audience: GarmentAudience?
    /// The model's measurements and worn size, if the page states them.
    public var modelFit: ModelFit?
    /// Lowest price the page offers, and its currency (schema.org offers).
    public var price: Double?
    public var currency: String?
    /// Whether each size is in stock, for the sizes whose offer says so.
    public var sizeStock: [String: Bool] = [:]

    public init() {}

    /// Stable key for quota accounting and "already analysed" checks.
    public var productKey: String? {
        if let gtin { return "gtin:\(gtin)" }
        if let pageURL { return "url:\(ProductPageParser.canonical(pageURL))" }
        return nil
    }

    public var isEmpty: Bool { name == nil && gtin == nil && availableSizes.isEmpty }
}

/// Reads schema.org Product JSON-LD (most shops) with an OpenGraph fallback.
/// Size charts are almost never in structured data; callers fall back to OCR.
public struct ProductPageParser: Sendable {
    public init() {}

    public func parse(html: String, pageURL: URL?) -> ProductInfo {
        var info = ProductInfo()
        info.pageURL = pageURL

        for object in Self.jsonLDObjects(in: html) {
            guard let product = Self.findProduct(in: object) else { continue }
            Self.apply(product, to: &info, base: pageURL)
            break
        }

        // Amazon has neither JSON-LD nor OpenGraph product data; read its page first so the
        // generic heading fallback doesn't take a layout heading for the name.
        if AmazonPage.isAmazon(html, url: pageURL) { AmazonPage.apply(html, to: &info) }

        let og = Self.metaTags(in: html)
        if info.name == nil { info.name = og["og:title"] ?? Self.firstHeading(in: html) }
        if info.brand == nil { info.brand = og["product:brand"] ?? og["og:brand"] }
        if info.imageURL == nil, let img = og["og:image"] { info.imageURL = URL(string: img, relativeTo: pageURL)?.absoluteURL }

        if info.availableSizes.isEmpty { info.availableSizes = Self.embeddedSizes(in: html) }
        info.sizeChartImageURLs = Self.sizeChartImages(in: html, base: pageURL)
        info.sizeChartSections = HTMLSizeTables.sections(in: html)
        let visible = Self.visibleText(html)
        info.modelFit = ModelFitParser.parse(visible)
        if info.material == nil { info.material = FabricAdvice.compositionText(in: visible) }

        let text = [info.name, info.categoryText].compactMap { $0 }.joined(separator: " ")
        // The brand isn't the garment: "Tommy Jeans … Shirt" is a shirt.
        let withoutBrand = info.brand.map { text.replacingOccurrences(of: $0, with: " ", options: .caseInsensitive) } ?? text
        info.category = GarmentClassifier.category(from: withoutBrand)
        info.fitStyle = GarmentClassifier.fitStyle(from: text)
        info.stretch = info.material.flatMap(GarmentClassifier.stretch(fromComposition:))
        info.audience = GarmentClassifier.audience(from: text + " " + (pageURL?.path ?? "") + " " + (og["og:description"] ?? ""))
        return info
    }

    // MARK: - Embedded page data

    /// Many shops render from a JSON state blob instead of JSON-LD. Size labels there
    /// sit under keys like "size" or "value"; only letter sizes are taken, because a
    /// bare number under "value" could be anything.
    static func embeddedSizes(in html: String) -> [String] {
        let pattern = #""(?:size|sizeName|value|attributeValue|beautifiedValue)"\s*:\s*"(XXS|XS|S|M|L|XL|XXL|XXXL|2XL|3XL|4XL|5XL)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var sizes: [String] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range(at: 1)).uppercased()
            if !sizes.contains(s) { sizes.append(s) }
        }
        return sizes
    }

    /// Image links whose key or file name says "size chart" (any common spelling,
    /// Turkish included). JSON-escaped slashes are unescaped.
    static func sizeChartImages(in html: String, base: URL?) -> [URL] {
        let patterns = [
            #""(?:size_?chart|size_?guide|beden_?tablosu)[A-Za-z_]*"\s*:\s*"([^"]+?)""#,
            #"<img[^>]+src\s*=\s*["']([^"']*(?:size-?chart|size-?guide|beden-?tablosu|olcu-?tablosu)[^"']*)["']"#,
        ]
        var urls: [URL] = []
        let ns = html as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let raw = ns.substring(with: m.range(at: 1))
                    .replacingOccurrences(of: #"\u002F"#, with: "/", options: .caseInsensitive)
                    .replacingOccurrences(of: #"\/"#, with: "/")
                    .replacingOccurrences(of: "&amp;", with: "&")
                guard let url = URL(string: raw, relativeTo: base)?.absoluteURL,
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      ["jpg", "jpeg", "png", "webp", "gif"].contains(url.pathExtension.lowercased()),
                      !urls.contains(url) else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - JSON-LD

    static func jsonLDObjects(in html: String) -> [Any] {
        let pattern = #"<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let body = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return body.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        }
    }

    static func findProduct(in object: Any) -> [String: Any]? {
        if let array = object as? [Any] {
            return array.lazy.compactMap(findProduct).first
        }
        guard let dict = object as? [String: Any] else { return nil }
        if isType(dict, "Product") || isType(dict, "ProductGroup") { return dict }
        if let graph = dict["@graph"] { return findProduct(in: graph) }
        if let main = dict["mainEntity"] { return findProduct(in: main) }
        return nil
    }

    private static func isType(_ dict: [String: Any], _ type: String) -> Bool {
        if let t = dict["@type"] as? String { return t == type || t.hasSuffix("/\(type)") }
        if let ts = dict["@type"] as? [String] { return ts.contains(type) }
        return false
    }

    private static func apply(_ p: [String: Any], to info: inout ProductInfo, base: URL?) {
        info.name = string(p["name"])
        info.brand = string(p["brand"]) ?? string((p["brand"] as? [String: Any])?["name"])
        info.imageURL = imageURL(p["image"], base: base)
        info.gtin = ["gtin13", "gtin", "gtin12", "gtin14", "gtin8"].lazy.compactMap { string(p[$0]) }.first
        info.sku = string(p["sku"])
        info.categoryText = string(p["category"])
        info.material = string(p["material"])

        var sizes: [String] = []
        func add(_ raw: String?) {
            // "S (US S)" → "S": keep the store's own label, drop the conversion in brackets.
            let s = raw.map { $0.components(separatedBy: " (").first ?? $0 }?.trimmingCharacters(in: .whitespaces)
            guard let s, !s.isEmpty, !sizes.contains(s) else { return }
            sizes.append(s)
        }
        func offers(_ v: Any?) -> [[String: Any]] {
            (v as? [[String: Any]]) ?? ((v as? [String: Any]).map { [$0] } ?? [])
        }
        func read(_ offer: [String: Any], size: String?) {
            if let price = number(offer["price"] ?? offer["lowPrice"]), price > 0 {
                info.price = min(info.price ?? price, price)
            }
            if info.currency == nil { info.currency = string(offer["priceCurrency"]) }
            if let size, let availability = string(offer["availability"])?.lowercased() {
                let available = availability.contains("instock") || availability.contains("limitedavailability")
                info.sizeStock[size] = (info.sizeStock[size] ?? false) || available
            }
        }
        func label(_ raw: String?) -> String? {
            raw.map { $0.components(separatedBy: " (").first ?? $0 }?.trimmingCharacters(in: .whitespaces)
        }
        if let s = p["size"] as? [Any] { s.forEach { add(string($0)) } } else { add(string(p["size"])) }
        for variant in (p["hasVariant"] as? [[String: Any]]) ?? [] {
            let size = string(variant["size"])
            add(size)
            if info.gtin == nil { info.gtin = string(variant["gtin13"]) ?? string(variant["gtin"]) }
            offers(variant["offers"]).forEach { read($0, size: label(size)) }
        }
        for offer in offers(p["offers"]) {
            let size = string(offer["size"]) ?? string((offer["itemOffered"] as? [String: Any])?["size"])
            add(size)
            read(offer, size: label(size))
        }
        info.availableSizes = sizes
    }

    /// "1.299,90", "1299.90", 1299.9 → 1299.9.
    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            var t = s.trimmingCharacters(in: .whitespaces).filter { $0.isNumber || $0 == "." || $0 == "," }
            if t.contains(","), t.contains(".") {
                // The later separator is the decimal one.
                if t.lastIndex(of: ",")! > t.lastIndex(of: ".")! { t = t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
                else { t = t.replacingOccurrences(of: ",", with: "") }
            } else {
                t = t.replacingOccurrences(of: ",", with: ".")
            }
            return Double(t)
        default: return nil
        }
    }

    private static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : decodeEntities(t)
        case let n as NSNumber: return n.stringValue
        case let d as [String: Any]: return string(d["name"])
        default: return nil
        }
    }

    private static func imageURL(_ v: Any?, base: URL?) -> URL? {
        switch v {
        case let s as String: URL(string: s, relativeTo: base)?.absoluteURL
        case let a as [Any]: a.lazy.compactMap { imageURL($0, base: base) }.first
        case let d as [String: Any]: imageURL(d["url"] ?? d["contentUrl"], base: base)
        default: nil
        }
    }

    // MARK: - Meta tags

    /// Page text without scripts, styles and tags.
    static func visibleText(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// The page's main heading, for stores with neither JSON-LD nor OpenGraph.
    static func firstHeading(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<h1\b[^>]*>(.*?)</h1>"#, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { return nil }
        let text = (html as NSString).substring(with: m.range(at: 1))
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty || text.count > 150 ? nil : decodeEntities(text)
    }

    static func metaTags(in html: String) -> [String: String] {
        let pattern = #"<meta\s+[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [:] }
        let ns = html as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let key = attribute("property", in: tag) ?? attribute("name", in: tag),
                  let content = attribute("content", in: tag) else { continue }
            if result[key.lowercased()] == nil { result[key.lowercased()] = decodeEntities(content) }
        }
        return result
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return (tag as NSString).substring(with: m.range(at: 1))
    }

    static func decodeEntitiesForAmazon(_ s: String) -> String { decodeEntities(s) }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    /// Host + path without query/fragment, so tracking parameters don't create new products.
    static func canonical(_ url: URL) -> String {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: true)
        c?.query = nil
        c?.fragment = nil
        let s = c?.string ?? url.absoluteString
        return (s.hasSuffix("/") ? String(s.dropLast()) : s).lowercased()
    }
}

/// Keyword heuristics for Turkish and English product names.
public enum GarmentClassifier {
    public static func category(from text: String) -> GarmentCategory? {
        let t = SizeChartParser.fold(text)
        let rules: [(GarmentCategory, [String])] = [
            (.pants, ["pantolon", "jean", "kot ", "chino", "trouser", "pants", "jogger", "esofman alti"]),
            (.jacket, ["ceket", "mont", "blazer", "jacket", "coat", "kaban", "parka"]),
            (.tshirt, ["t-shirt", "tisort", "tshirt", "tee", "polo"]),
            (.shirt, ["gomlek", "shirt", "bluz", "blouse"]),
        ]
        return rules.first { _, keys in keys.contains { t.contains($0) } }?.0
    }

    public static func fitStyle(from text: String) -> FitStyle? {
        let t = SizeChartParser.fold(text)
        if ["oversize", "oversized", "bol kesim", "boxy"].contains(where: t.contains) { return .oversized }
        if ["relaxed", "loose", "rahat kesim", "wide leg", "genis paca"].contains(where: t.contains) { return .relaxed }
        if ["slim", "skinny", "dar kesim", "muscle fit", "super slim"].contains(where: t.contains) { return .slim }
        if ["regular", "standart kesim", "classic fit", "normal kesim"].contains(where: t.contains) { return .regular }
        return nil
    }

    /// Reads elastane/spandex/lycra share from "98% cotton, 2% elastane" or "%98 Pamuk %2 Elastan".
    public static func stretch(fromComposition text: String) -> FabricStretch? {
        let t = SizeChartParser.fold(text)
        let pattern = #"(?:%\s*(\d+(?:[.,]\d+)?)\s*(elastan\w*|spandex|lycra))|(?:(\d+(?:[.,]\d+)?)\s*%\s*(elastan\w*|spandex|lycra))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = t as NSString
        var percent = 0.0
        for m in regex.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 3)
            percent += Double(ns.substring(with: r).replacingOccurrences(of: ",", with: ".")) ?? 0
        }
        guard t.contains("%") else { return nil }
        switch percent {
        case 0: return FabricStretch.none  // `.none` alone would mean Optional.none
        case ..<3: return .low
        case ..<5: return .medium
        default: return .high
        }
    }
}
