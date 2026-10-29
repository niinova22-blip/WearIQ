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
        // "32", "32/34", "W32", "38-40": the first number decides.
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
