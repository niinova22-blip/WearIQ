import Foundation
import WearIQCore

/// Zara (and the other Inditex stores on the same platform) don't put the size guide in
/// the page: the "Ürün boyutları" panel asks the store's catalogue for it, as plain JSON:
///
///     /itxrest/5/catalog/store/{storeId}/product/{catentryId}/size-measure-guide?locale=tr_TR
///
/// The same request the page makes, with the ids the page carries. `measureGuideInfo`
/// lists the garment laid flat (girths are side to side, half the circumference);
/// `sizeGuideInfo`, when a product has one, the body each size fits.
public enum InditexSizeGuide {
    /// The guide's address for a product page, or nil when the page isn't one of these.
    public static func url(html: String, pageURL: URL) -> URL? {
        guard let host = pageURL.host, let scheme = pageURL.scheme,
              let store = first(#""storeId"\s*:\s*(\d{4,6})\b"#, in: html),
              let product = first(#""catentryId"\s*:\s*(\d{6,12})\b"#, in: html)
                ?? first(#""sku"\s*:\s*"(\d{6,12})-\d+-[^"]*""#, in: html) else { return nil }
        let locale = first(#""locale"\s*:\s*"([a-z]{2}_[A-Z]{2})"#, in: html)
            ?? pathLocale(pageURL) ?? "en_GB"
        return URL(string: "\(scheme)://\(host)/itxrest/5/catalog/store/\(store)/product/\(product)/size-measure-guide?locale=\(locale)")
    }

    /// "/tr/tr/…" → "tr_TR"; "/tr/en/…" → "en_TR".
    static func pathLocale(_ url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0].count == 2, parts[1].count == 2 else { return nil }
        return parts[1].lowercased() + "_" + parts[0].uppercased()
    }

    /// The chart for a garment of `category`: the body guide when there is one, the
    /// garment's own measurements otherwise.
    public static func chart(from data: Data, category: GarmentCategory?) -> ParsedSizeChart? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let body = json["sizeGuideInfo"] as? [String: Any], let chart = chart(body, kind: .body, category: category) {
            return chart
        }
        if let garment = json["measureGuideInfo"] as? [String: Any] {
            return chart(garment, kind: .garment, category: category)
        }
        return nil
    }

    private static func chart(_ guide: [String: Any], kind: SizeChartKind, category: GarmentCategory?) -> ParsedSizeChart? {
        guard let sizes = guide["sizes"] as? [[String: Any]] else { return nil }
        var entries: [SizeEntry] = []
        var doubled = Set<GarmentDimension>()
        for size in sizes {
            guard let rawName = size["name"] as? String, let name = ProductPageParser.sizeLabel(rawName), !name.isEmpty
            else { continue }
            var values: [GarmentDimension: MeasuredValue] = [:]
            for measure in (size["measures"] as? [[String: Any]]) ?? [] {
                let title = SizeChartParser.fold((measure["tableTitle"] as? String) ?? (measure["name"] as? String) ?? "")
                guard var dim = SizeChartParser.dimension(for: title),
                      let cm = centimetres(measure["dimensions"]) else { continue }
                // A trouser's "total length" runs from the waistband to the hem: the outseam.
                if dim == .bodyLength, category?.isBottom ?? false { dim = .outseam }
                var value = cm
                // The garment is measured flat: a girth is twice the width across.
                if kind == .garment, SizeChartParser.isGirth(dim) {
                    value *= 2
                    doubled.insert(dim)
                }
                values[dim] = MeasuredValue(cm: value, uncertaintyCm: kind == .garment ? 1 : 2, source: .manual)
            }
            if !values.isEmpty, !entries.contains(where: { $0.label == name }) {
                entries.append(SizeEntry(label: name, values: values))
            }
        }
        guard entries.count >= 2 else { return nil }
        let warnings = doubled.sorted { $0.rawValue < $1.rawValue }.map(ParsedSizeChart.Warning.halfMeasurementsDoubled)
        // No plausibility pass: the guide says what it measures, and a small top's doubled
        // 68 cm chest would read there as half a garment again.
        return ParsedSizeChart(sizes: SizeOrder.sorted(entries), kind: kind, unit: .cm, warnings: warnings)
    }

    private static func centimetres(_ v: Any?) -> Double? {
        for d in (v as? [[String: Any]]) ?? [] where (d["unitId"] as? String)?.lowercased() == "cm" {
            if let s = d["value"] as? String, let n = Double(s.replacingOccurrences(of: ",", with: ".")) { return n }
            if let n = d["value"] as? Double { return n }
        }
        return nil
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
