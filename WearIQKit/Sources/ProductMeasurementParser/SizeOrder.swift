import Foundation
import WearIQCore

/// Puts size labels in wearing order (XS, S, M, L, XL… or 28, 30, 32…). Stores list them
/// in any order, and the fit engine compares each size with its neighbours.
public enum SizeOrder {
    static let letters = ["XXXS", "3XS", "XXS", "2XS", "XS", "S", "M", "L", "XL", "XXL", "2XL", "XXXL", "3XL", "4XL", "5XL"]

    /// A sortable rank, or nil for labels that aren't recognised.
    static func rank(_ label: String) -> Double? {
        let l = label.uppercased().trimmingCharacters(in: .whitespaces)
        if let i = letters.firstIndex(of: l) {
            // 2XL and XXL (and their kin) are the same size.
            let canonical = ["2XS": "XXS", "3XS": "XXXS", "2XL": "XXL", "3XL": "XXXL"][l] ?? l
            return Double(letters.firstIndex(of: canonical) ?? i)
        }
        // Waist and length: by waist, then length (31/30, 31/32, 32/30).
        if let wl = SizeLabel.waistLength(l) { return 1000 + Double(wl.waist) + Double(wl.length) / 100 }
        // "32", "W32", "38-40": the first number decides.
        let digits = l.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." || $0 == "," }
        return Double(digits.replacingOccurrences(of: ",", with: ".")).map { 1000 + $0 }
    }

    /// Recognised labels in wearing order; unrecognised ones keep their place after them.
    public static func sorted(_ sizes: [SizeEntry]) -> [SizeEntry] {
        let ranked = sizes.enumerated().map { (offset: $0.offset, rank: rank($0.element.label), size: $0.element) }
        guard ranked.contains(where: { $0.rank != nil }) else { return sizes }
        return ranked.sorted { a, b in
            switch (a.rank, b.rank) {
            case let (x?, y?): x == y ? a.offset < b.offset : x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.size)
    }
}

/// Size labels as stores write them.
public enum SizeLabel {
    /// Waist and length in inches, as jeans and many trousers are sold everywhere:
    /// "31/32", "W31 L32", "W31/L32", "31x32", "31 32". Nil for anything else, a single
    /// size or a double one ("S/M"). A plain "36/38" also reads as W36 L38; callers
    /// apply it to trousers only, where that's what it means.
    public static func waistLength(_ label: String) -> (waist: Int, length: Int)? {
        let l = label.uppercased().trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: #"^W?\s*(\d{2})\s*(?:/|X|\s)\s*L?\s*(\d{2})$"#),
              let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
              let wr = Range(m.range(at: 1), in: l), let lr = Range(m.range(at: 2), in: l),
              let w = Int(l[wr]), let len = Int(l[lr]),
              (22...52).contains(w), (26...38).contains(len) else { return nil }
        return (w, len)
    }

    /// A size written with its US equivalent, as Inditex stores (Zara, Bershka, Pull&Bear)
    /// label trousers: "EU 38 (US 30)". Returns the European number and the US one; nil
    /// for labels without a numeric US part ("S (US S)").
    public static func withUS(_ label: String) -> (eu: Int?, us: Int)? {
        let l = label.uppercased()
        guard let re = try? NSRegularExpression(pattern: #"^\s*(?:EU\s*)?(\d{1,2})?\s*\(\s*US\s*(\d{1,2})\s*\)\s*$"#),
              let m = re.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
              let ur = Range(m.range(at: 2), in: l), let us = Int(l[ur]) else { return nil }
        let eu = Range(m.range(at: 1), in: l).flatMap { Int(l[$0]) }
        return (eu, us)
    }

    /// The number a store's size label stands for, for reading it as a standard size:
    /// trousers labelled "EU 38 (US 30)" are a 30 in waist (the US number is the waist in
    /// inches, "W30"); other "EU 36" or "36 (US 4)" labels are the European 36.
    public static func standardReading(_ label: String, category: GarmentCategory?) -> String {
        if let pair = withUS(label) {
            if category?.isBottom ?? true, (24...50).contains(pair.us) { return "W\(pair.us)" }
            if let eu = pair.eu { return String(eu) }
            return String(pair.us)
        }
        let l = label.trimmingCharacters(in: .whitespaces)
        if l.uppercased().hasPrefix("EU"), let n = Int(l.dropFirst(2).trimmingCharacters(in: .whitespaces)) { return String(n) }
        return l
    }

    /// One spelling per size, to tell whether two labels are the same size: "W31 L32"
    /// and "31/32" are; "2XL" and "XXL" are.
    public static func normalized(_ label: String) -> String {
        if let wl = waistLength(label) { return "\(wl.waist)/\(wl.length)" }
        let l = label.uppercased().replacingOccurrences(of: " ", with: "")
        return ["2XS": "XXS", "3XS": "XXXS", "2XL": "XXL", "3XL": "XXXL"][l] ?? l
    }
}
