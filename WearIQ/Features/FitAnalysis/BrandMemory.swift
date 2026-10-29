import Foundation
import WearIQCore

/// What the user's earlier purchases say about a brand: whether it tends to come out
/// tight or loose on them, so a recommendation for the same brand can be nudged.
struct BrandMemory {
    enum Lean: Equatable {
        case runsSmall, trueToSize, runsLarge
    }

    let records: [PurchaseRecord]

    /// Records for this brand, the same category first if there are any.
    func relevant(brand: String?, category: GarmentCategory?) -> [PurchaseRecord] {
        guard let brand = brand.map(Self.normalized), !brand.isEmpty else { return [] }
        let same = records.filter { Self.normalized($0.brand) == brand }
        let sameCategory = same.filter { $0.category == category }
        return sameCategory.isEmpty ? same : sameCategory
    }

    /// Average of tight (−1), right (0) and loose (+1); half a step or more either way
    /// counts as a lean.
    func lean(brand: String?, category: GarmentCategory?) -> Lean? {
        let r = relevant(brand: brand, category: category)
        guard !r.isEmpty else { return nil }
        let score = r.map { record -> Double in
            switch record.feel {
            case .tight: -1
            case .right: 0
            case .loose: 1
            }
        }.reduce(0, +) / Double(r.count)
        if score <= -0.5 { return .runsSmall }
        if score >= 0.5 { return .runsLarge }
        return .trueToSize
    }

    /// One sentence for the result screen, or nil without purchases of this brand.
    func note(brand: String?, category: GarmentCategory?, recommended: String?) -> String? {
        let r = relevant(brand: brand, category: category)
        guard let latest = r.max(by: { $0.createdAt < $1.createdAt }), let lean = lean(brand: brand, category: category),
              let brand else { return nil }
        let feel: String = switch latest.feel {
        case .tight: String(localized: "tight")
        case .right: String(localized: "just right")
        case .loose: String(localized: "loose")
        }
        let history = String(localized: "You bought \(latest.size) from \(brand) and it was \(feel).")
        switch lean {
        case .runsSmall:
            return history + " " + String(localized: "This brand tends to come out small on you; consider one size up.")
        case .runsLarge:
            return history + " " + String(localized: "This brand tends to come out large on you; consider one size down.")
        case .trueToSize:
            if let recommended, recommended != latest.size, latest.feel == .right {
                return history + " " + String(localized: "Compare with \(latest.size) if you liked that fit.")
            }
            return history
        }
    }

    private static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
