import Foundation
import WearIQCore

/// Where the user shops, which decides how sizes are written for them.
///
/// The same body is a different label in each system (docs/SIZE_SYSTEMS.md):
///
/// | Garment                  | Türkiye            | Europe (EN 13402)   | United States       |
/// |--------------------------|--------------------|---------------------|---------------------|
/// | Tops, knitwear, jackets  | XS–XXL             | XS–XXL              | XS–XXL              |
/// | Women's dresses, skirts  | 34–46 (36 = S)     | 34–46 (FR/ES/TR)    | 0–16 (US 4 = EU 36) |
/// | Women's trousers         | 34–46              | 34–46               | 0–16                |
/// | Jeans (men and women)    | W/L inches (31/32) | W/L inches          | W/L inches          |
/// | Men's trousers (non-denim) | 44–58 (48 = W32) | 44–58               | W/L inches          |
///
/// Store labels always win: a size is recommended in the store's own labels, because
/// that is what is bought. The system matters where the store gives none (typical
/// sizes are then listed in the user's system) and to show a store's label in the
/// user's system ("US 6" is "TR 38").
public enum SizeRegion: String, CaseIterable, Codable, Sendable {
    case tr, eu, us

    /// From the app's language and the device's region: Turkish → Türkiye; English in
    /// the United States → US; otherwise Europe.
    public static func automatic(language: String?, region: String?) -> SizeRegion {
        let lang = language?.lowercased().prefix(2)
        if lang == "tr" || region?.uppercased() == "TR" { return .tr }
        if region?.uppercased() == "US" { return .us }
        return .eu
    }

    /// Short name shown before a converted size: "TR 38", "EU 38", "US 6".
    public var code: String {
        switch self {
        case .tr: "TR"
        case .eu: "EU"
        case .us: "US"
        }
    }
}

public enum SizeSystems {
    static let letters = ["XS", "S", "M", "L", "XL", "XXL", "3XL"]
    static let menWaists = [28, 29, 30, 31, 32, 33, 34, 36, 38, 40]
    static let womenWaists = [24, 25, 26, 27, 28, 29, 30, 31, 32, 34]

    /// Jeans and denim, which are sold by waist and length everywhere.
    public static func isDenim(_ name: String?) -> Bool {
        guard let name else { return false }
        let t = " " + SizeChartParser.fold(name) + " "
        return [" jean", "denim", " kot "].contains(where: t.contains)
    }

    /// The sizes a store in `region` usually offers for this garment, in wearing order:
    /// what to compare the body with when a store lists none.
    public static func ladder(for category: GarmentCategory, audience: GarmentAudience?, region: SizeRegion,
                              productName: String? = nil) -> [String] {
        let women = audience == .women
        let denim = isDenim(productName)
        func waistLength(_ waists: [Int], _ lengths: [Int]) -> [String] {
            waists.flatMap { w in lengths.map { "\(w)/\($0)" } }
        }
        func numbers(_ r: StrideThrough<Int>) -> [String] { r.map(String.init) }
        switch category {
        case .tshirt, .shirt, .sweater, .jacket, .coat:
            return letters
        case .pants:
            if women {
                if denim { return waistLength(womenWaists, [30, 32]) }
                return region == .us ? numbers(stride(from: 0, through: 16, by: 2)) : numbers(stride(from: 34, through: 46, by: 2))
            }
            if denim || region == .us { return waistLength(menWaists, [30, 32, 34]) }
            return numbers(stride(from: 44, through: 58, by: 2))
        case .shorts:
            if women { return region == .us ? numbers(stride(from: 0, through: 14, by: 2)) : numbers(stride(from: 34, through: 44, by: 2)) }
            return region == .us ? menWaists.map(String.init) : letters
        case .dress, .skirt:
            if !women { return letters }
            return region == .us ? numbers(stride(from: 0, through: 16, by: 2)) : numbers(stride(from: 34, through: 46, by: 2))
        }
    }

    /// The store's `label` as the user's system writes it, or nil when it already is
    /// (letters are letters everywhere, jeans are W/L everywhere) or the label isn't
    /// known. Found by body: the typical body for the store's size, matched to the
    /// nearest size of the user's system on the measurements that decide the size.
    public static func equivalent(of label: String, storeLabels: [String], category: GarmentCategory,
                                  audience: GarmentAudience?, region: SizeRegion, productName: String? = nil) -> String? {
        let ladder = ladder(for: category, audience: audience, region: region, productName: productName)
        let normalized = SizeLabel.normalized(label)
        if ladder.contains(where: { SizeLabel.normalized($0) == normalized }) { return nil }
        // Same system already (both letters, or both W/L): nothing to convert.
        let own = kind(of: label, category: category, audience: audience)
        if own == kind(of: ladder.first ?? "", category: category, audience: audience) { return nil }
        // Already in a system native to the region: a men's 50 jacket is a Turkish and a
        // European size; a US 6 is American.
        if own == .european, region != .us { return nil }
        if own == .usWomen, region == .us { return nil }
        let labels = storeLabels.contains(label) ? storeLabels : storeLabels + [label]
        guard let store = StandardSizeCharts.chart(for: labels, category: category, audience: audience),
              let size = store.sizes.first(where: { $0.label == label }),
              let target = StandardSizeCharts.chart(for: ladder, category: category, audience: audience) else { return nil }
        let dims: [GarmentDimension] = category.isBottom ? [.waist, .hip, .inseam] : [.chest, .waist]
        func distance(_ other: SizeEntry) -> Double? {
            var sum = 0.0, n = 0
            for d in dims {
                guard let a = size.values[d]?.cm, let b = other.values[d]?.cm else { continue }
                sum += (a - b) * (a - b)
                n += 1
            }
            return n == 0 ? nil : sum / Double(n)
        }
        let best = target.sizes.compactMap { s in distance(s).map { (s.label, $0) } }.min { $0.1 < $1.1 }
        guard let best, best.1 < 64 else { return nil }   // more than 8 cm off: no honest equivalent
        return best.0
    }

    /// Which system a label is written in.
    enum Kind { case letters, waistLength, european, usWomen, inches, other }

    static func kind(of label: String, category: GarmentCategory, audience: GarmentAudience?) -> Kind {
        if category.isBottom, SizeLabel.waistLength(label) != nil { return .waistLength }
        let l = label.uppercased().trimmingCharacters(in: .whitespaces)
        if SizeOrder.letters.contains(l) { return .letters }
        guard let n = Int(l.hasPrefix("W") ? String(l.dropFirst()) : l) else { return .other }
        if audience == .women { return n <= 22 ? .usWomen : (n >= 32 && n % 2 == 0 ? .european : .inches) }
        return n >= 42 && n % 2 == 0 ? .european : .inches
    }
}
