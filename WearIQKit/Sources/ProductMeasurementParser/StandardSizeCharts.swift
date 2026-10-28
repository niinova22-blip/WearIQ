import Foundation
import WearIQCore

/// Who a garment is cut for. Size labels mean different bodies for each.
public enum GarmentAudience: String, Sendable, Equatable {
    case men, women
}

/// Typical BODY measurements behind common size labels, for products whose store
/// publishes no size chart. Ranges follow the usual European high-street conventions
/// (EN 13402-style 8 cm steps for men's letter sizes, 4 cm steps for EU numeric sizes).
/// Brands differ by a size or so, which is why these charts carry wide uncertainty and
/// the UI says the advice is based on a standard chart, not the store's own.
public enum StandardSizeCharts {
    /// (chest, waist, hip) body ranges in cm.
    private typealias Ranges = (chest: ClosedRange<Double>, waist: ClosedRange<Double>, hip: ClosedRange<Double>)

    private static let menLetters: [String: Ranges] = [
        "XS": (80...88, 68...76, 84...92), "S": (88...96, 76...84, 92...100), "M": (96...104, 84...92, 100...108),
        "L": (104...112, 92...100, 108...116), "XL": (112...120, 100...108, 116...124),
        "XXL": (120...128, 108...116, 124...132), "2XL": (120...128, 108...116, 124...132),
        "XXXL": (128...136, 116...124, 132...140), "3XL": (128...136, 116...124, 132...140),
    ]

    private static let womenLetters: [String: Ranges] = [
        "XXS": (74...78, 58...62, 82...86), "XS": (78...82, 62...66, 86...90), "S": (82...86, 66...70, 90...94),
        "M": (86...92, 70...76, 94...100), "L": (92...100, 76...84, 100...108), "XL": (100...108, 84...92, 108...116),
        "XXL": (108...116, 92...100, 116...124), "2XL": (108...116, 92...100, 116...124),
    ]

    /// A chart for the given size labels, or nil if none of them is a known label.
    public static func chart(for labels: [String], category: GarmentCategory?, audience: GarmentAudience?) -> ParsedSizeChart? {
        let audience = audience ?? .men
        let sizes = labels.compactMap { label -> SizeEntry? in
            guard let r = ranges(for: label, category: category, audience: audience) else { return nil }
            func v(_ range: ClosedRange<Double>) -> MeasuredValue {
                // Range half-width plus a size step's worth of brand-to-brand variation.
                MeasuredValue(cm: (range.lowerBound + range.upperBound) / 2,
                              uncertaintyCm: (range.upperBound - range.lowerBound) / 2 + 2, source: .manual)
            }
            var values: [GarmentDimension: MeasuredValue] = [.waist: v(r.waist), .hip: v(r.hip)]
            if category != .pants { values[.chest] = v(r.chest) }
            return SizeEntry(label: label, values: values)
        }
        guard !sizes.isEmpty else { return nil }
        return ParsedSizeChart(sizes: sizes, kind: .body, unit: .cm, warnings: [.standardChartUsed])
    }

    private static func ranges(for rawLabel: String, category: GarmentCategory?, audience: GarmentAudience) -> Ranges? {
        let label = rawLabel.uppercased().trimmingCharacters(in: .whitespaces)
        if let r = (audience == .men ? menLetters : womenLetters)[label] { return r }
        guard let n = Int(label.split(separator: "/").first.map(String.init) ?? label) else { return nil }
        // Jeans and trousers in inches (W30): waist ≈ size × 2.54.
        if (category == .pants || category == nil) && (24...40).contains(n) && (audience == .men || category == .pants) {
            let waist = Double(n) * 2.54
            return (waist + 10...waist + 18, waist - 2...waist + 2, waist + 14...waist + 20)
        }
        if audience == .men, (44...62).contains(n) {
            // EU men's sizes: chest ≈ 2 × size.
            let chest = Double(n * 2)
            return (chest - 2...chest + 2, chest - 14...chest - 8, chest + 2...chest + 8)
        }
        if audience == .women, (32...54).contains(n), n % 2 == 0 {
            // EU women's sizes: 36 → bust 84, waist 68, hip 92; 4 cm per size.
            let step = Double(n - 36) * 2
            return (82 + step...86 + step, 66 + step...70 + step, 90 + step...94 + step)
        }
        return nil
    }
}

extension GarmentClassifier {
    /// Men's or women's, from the product name, category text or URL.
    public static func audience(from text: String) -> GarmentAudience? {
        let t = SizeChartParser.fold(text)
        let women = ["kadin", "women", "woman", "bayan", "ladies", "/kadin", "female"]
        let men = ["erkek", " men", "/men", "man ", "bay ", "male"]
        if women.contains(where: t.contains) { return .women }
        if men.contains(where: t.contains) { return .men }
        return nil
    }
}
