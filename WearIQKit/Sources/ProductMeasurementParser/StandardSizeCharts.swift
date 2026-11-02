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
        "4XL": (136...144, 124...132, 140...148), "XXXXL": (136...144, 124...132, 140...148),
        "5XL": (144...152, 132...140, 148...156),
    ]

    private static let womenLetters: [String: Ranges] = [
        "XXS": (74...78, 58...62, 82...86), "XS": (78...82, 62...66, 86...90), "S": (82...86, 66...70, 90...94),
        "M": (86...92, 70...76, 94...100), "L": (92...100, 76...84, 100...108), "XL": (100...108, 84...92, 108...116),
        "XXL": (108...116, 92...100, 116...124), "2XL": (108...116, 92...100, 116...124),
        // Plus sizes: the same 8 cm steps on (EN 13402 continues them to bust 140+).
        "XXXL": (116...124, 100...108, 124...132), "3XL": (116...124, 100...108, 124...132),
        "4XL": (124...132, 108...116, 132...140), "XXXXL": (124...132, 108...116, 132...140),
        "5XL": (132...140, 116...124, 140...148),
    ]

    /// A chart for the given size labels, or nil if none of them is a known label.
    /// With an `anchor` (the model's body and the size they wear), the whole chart is
    /// shifted so that size matches the model: this captures how the brand cuts.
    public static func chart(for labels: [String], category: GarmentCategory?, audience: GarmentAudience?,
                             anchor: ModelFit? = nil) -> ParsedSizeChart? {
        guard var chart = chart(for: labels, category: category, audience: audience) else { return nil }
        guard let anchor, let worn = anchor.size,
              let reference = chart.sizes.first(where: { $0.label.uppercased() == worn }) else { return chart }
        if let height = anchor.heightCm, (140...210).contains(height) {
            addLengths(to: &chart, modelHeight: height, category: category, worn: reference.label)
        }
        guard anchor.isAnchor else { return chart }
        var shifted = false
        for (dim, value) in [(GarmentDimension.chest, anchor.chestCm), (.waist, anchor.waistCm), (.hip, anchor.hipCm)] {
            guard let value, let standard = reference.values[dim]?.cm else { continue }
            // A brand runs a size or so off the standard; more than that is a misread.
            let offset = max(-8, min(8, value - standard))
            for i in chart.sizes.indices {
                if let v = chart.sizes[i].values[dim] {
                    chart.sizes[i].values[dim] = MeasuredValue(cm: v.cm + offset, uncertaintyCm: max(2, v.uncertaintyCm - 2), source: .manual)
                }
            }
            shifted = true
        }
        if shifted { chart.warnings.append(.anchoredToModel(size: worn)) }
        return chart
    }

    /// The garment was made to look right on the model, so the size the model wears has
    /// lengths that suit a body of the model's height. From ANSUR II stature fractions:
    /// crotch height 0.481 (inseam), cervicale − navel 0.262 (top length), acromion −
    /// wrist 0.3375 (sleeve). Stated as the body each size fits (body chart).
    ///
    /// The other sizes are graded from it (`Grading`): a top two sizes up is longer in
    /// the body and the sleeves, as its pattern is, so an XL on someone who wears an M
    /// reads long, not "ideal" like every other size. Trouser inseams are left alone:
    /// they come in their own lengths (W/L) or are hemmed.
    static func addLengths(to chart: inout ParsedSizeChart, modelHeight h: Double, category: GarmentCategory?,
                           worn: String? = nil) {
        var lengths: [GarmentDimension: Double] = [:]
        switch category {
        case .pants?: lengths[.inseam] = 0.481 * h
        case .tshirt?: lengths[.bodyLength] = 0.262 * h
        case .shirt?, .jacket?, .sweater?:
            lengths[.bodyLength] = 0.262 * h
            lengths[.sleeveLength] = 0.3375 * h
        case .coat?:
            // A coat's length is its style (hip, knee, ankle), not a body length a size
            // suits: stated as one, it read "long" for every size and pulled the advice
            // to the smallest. Only the sleeves.
            lengths[.sleeveLength] = 0.3375 * h
        case .dress?, .skirt?, .shorts?:
            // A dress's or skirt's length is its style; without a stated one, none.
            break
        case nil: break
        }
        let reference = chart.sizes.first { $0.label == worn }?.values[.chest]?.cm
        for i in chart.sizes.indices {
            let chestSteps = reference.flatMap { r in chart.sizes[i].values[.chest].map { $0.cm - r } } ?? 0
            for (dim, cm) in lengths where chart.sizes[i].values[dim] == nil {
                let grade: Double = switch dim {
                case .bodyLength: chestSteps * Grading.lengthPerChest
                case .sleeveLength: chestSteps * Grading.sleevePerChest
                default: 0
                }
                // Where the hem falls on the model is a judgement call; ±3.5 cm.
                chart.sizes[i].values[dim] = MeasuredValue(cm: cm + grade, uncertaintyCm: 3.5, source: .manual)
            }
        }
    }

    public static func chart(for labels: [String], category: GarmentCategory?, audience: GarmentAudience?) -> ParsedSizeChart? {
        let audience = audience ?? .men
        let inches = waistInches(labels, category: category, audience: audience)
        let sizes = labels.compactMap { label -> SizeEntry? in
            guard let r = ranges(for: label, category: category, audience: audience, inches: inches) else { return nil }
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
        return ParsedSizeChart(sizes: SizeOrder.sorted(sizes), kind: .body, unit: .cm, warnings: [.standardChartUsed])
    }

    /// Whether a chart's numbers are waist inches (W30) rather than EU sizes. Men's
    /// trousers in 24–50 always are. Women's trousers are sold both ways: 34/36/38/40 is
    /// EU sizing (waist 66–76 cm) on most European sites, W26–W33 jeans are inches. Odd
    /// numbers, or nothing above 33, mean inches; even numbers reaching 34+ mean EU. Read
    /// as inches, a women's 38 had a 97 cm waist instead of 70.
    static func waistInches(_ labels: [String], category: GarmentCategory?, audience: GarmentAudience) -> Bool {
        let numbers = labels.compactMap { l in Int(l.uppercased().replacingOccurrences(of: "W", with: "")
            .split(separator: "/").first.map(String.init) ?? l) }
        guard !numbers.isEmpty else { return false }
        let trousers = category == .pants || category == .shorts
        if audience == .men { return trousers || category == nil }
        guard trousers else { return false }
        return numbers.contains { $0 % 2 == 1 } || numbers.max()! <= 33
    }

    private static func ranges(for rawLabel: String, category: GarmentCategory?, audience: GarmentAudience,
                               inches: Bool) -> Ranges? {
        let label = rawLabel.uppercased().trimmingCharacters(in: .whitespaces)
        if let r = (audience == .men ? menLetters : womenLetters)[label] { return r }
        let bare = label.hasPrefix("W") ? String(label.dropFirst()) : label
        guard let n = Int(bare.split(separator: "/").first.map(String.init) ?? bare) else { return nil }
        // Jeans and trousers in inches (W30): waist ≈ size × 2.54.
        let trousers = category == .pants || category == .shorts
        if inches && (24...(trousers ? 50 : 40)).contains(n) {
            let waist = Double(n) * 2.54
            return (waist + 10...waist + 18, waist - 2...waist + 2, waist + 14...waist + 20)
        }
        if audience == .men, (44...62).contains(n) {
            // EU men's sizes: chest ≈ 2 × size.
            let chest = Double(n * 2)
            return (chest - 2...chest + 2, chest - 14...chest - 8, chest + 2...chest + 8)
        }
        if audience == .women, (32...60).contains(n), n % 2 == 0 {
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
