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

    /// Inferred from name/category; `nil` when the text doesn't say.
    public var category: GarmentCategory?
    public var fitStyle: FitStyle?
    public var stretch: FabricStretch?

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

        let og = Self.metaTags(in: html)
        if info.name == nil { info.name = og["og:title"] }
        if info.brand == nil { info.brand = og["product:brand"] ?? og["og:brand"] }
        if info.imageURL == nil, let img = og["og:image"] { info.imageURL = URL(string: img, relativeTo: pageURL)?.absoluteURL }

        let text = [info.name, info.categoryText].compactMap { $0 }.joined(separator: " ")
        info.category = GarmentClassifier.category(from: text)
        info.fitStyle = GarmentClassifier.fitStyle(from: text)
        info.stretch = info.material.flatMap(GarmentClassifier.stretch(fromComposition:))
        return info
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
        func add(_ s: String?) {
            guard let s, !s.isEmpty, !sizes.contains(s) else { return }
            sizes.append(s)
        }
        if let s = p["size"] as? [Any] { s.forEach { add(string($0)) } } else { add(string(p["size"])) }
        for variant in (p["hasVariant"] as? [[String: Any]]) ?? [] {
            add(string(variant["size"]))
            if info.gtin == nil { info.gtin = string(variant["gtin13"]) ?? string(variant["gtin"]) }
        }
        let offers: [[String: Any]] = (p["offers"] as? [[String: Any]]) ?? ((p["offers"] as? [String: Any]).map { [$0] } ?? [])
        for offer in offers {
            add(string(offer["size"]) ?? string((offer["itemOffered"] as? [String: Any])?["size"]))
        }
        info.availableSizes = sizes
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
