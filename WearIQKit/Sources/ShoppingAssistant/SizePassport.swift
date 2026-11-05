import FitEngine
import Foundation
import ProductMeasurementParser
import WearIQCore

/// The size passport: the user's sizes in the usual systems, worked out from their body
/// with typical size charts (letters for tops, waist numbers for jeans, European numbers
/// for women's clothes), and how sizes compare from brand to brand from what they
/// checked and bought.
public enum SizePassport {
    public struct Line: Sendable, Equatable {
        public var category: GarmentCategory
        public var system: System
        public var size: String
        /// Between two sizes: the other one.
        public var otherSize: String?
    }

    public enum System: String, Sendable, Equatable {
        /// XS–XXL.
        case letters
        /// Women's European numbers (34–48).
        case european
        /// Trouser waist in inches (28–40).
        case waistInches
    }

    public static func lines(for body: BodyProfile) -> [Line] {
        let female = body.sex == .female
        let audience: GarmentAudience = female ? .women : .men
        let letters = ["XS", "S", "M", "L", "XL", "XXL", "XXXL"]
        var plan: [(GarmentCategory, System, [String])] = [
            (.tshirt, .letters, letters), (.shirt, .letters, letters), (.sweater, .letters, letters),
            (.jacket, .letters, letters), (.pants, .letters, letters),
        ]
        if female {
            let eu = ["32", "34", "36", "38", "40", "42", "44", "46", "48"]
            plan += [(.dress, .letters, letters), (.dress, .european, eu), (.skirt, .european, eu), (.pants, .european, eu)]
        } else {
            plan.append((.pants, .waistInches, ["28", "29", "30", "31", "32", "33", "34", "36", "38", "40"]))
        }
        return plan.compactMap { category, system, labels in
            guard let chart = StandardSizeCharts.chart(for: labels, category: category, audience: audience),
                  let kind = chart.kind, !chart.sizes.isEmpty else { return nil }
            let spec = GarmentSpec(category: category, chartKind: kind, sizes: SizeOrder.sorted(chart.sizes))
            switch FitEngine().analyze(body: body, garment: spec).recommendation {
            case let .size(label, _): return Line(category: category, system: system, size: label)
            case let .between(smaller, larger): return Line(category: category, system: system, size: smaller, otherSize: larger)
            case .insufficientData: return nil
            }
        }
    }

    /// One brand's size for a kind of garment, from a check or a purchase.
    public struct BrandSize: Sendable, Equatable {
        public var brand: String
        public var category: GarmentCategory?
        public var size: String
        /// From a purchase the user said fit right (surer than a check).
        public var confirmed: Bool

        public init(brand: String, category: GarmentCategory?, size: String, confirmed: Bool) {
            self.brand = brand; self.category = category; self.size = size; self.confirmed = confirmed
        }
    }

    /// Brands side by side for each kind of garment: one size per brand, a confirmed
    /// purchase over a check, the newest first given in order. Only kinds with two or
    /// more brands, where there's something to compare.
    public static func compare(_ sizes: [BrandSize]) -> [(category: GarmentCategory?, brands: [BrandSize])] {
        var byKind: [String: [String: BrandSize]] = [:]
        var order: [String] = []
        for s in sizes {
            let kind = s.category?.rawValue ?? "", brand = s.brand.trimmingCharacters(in: .whitespaces).lowercased()
            if byKind[kind] == nil { order.append(kind) }
            if let existing = byKind[kind]?[brand], existing.confirmed || !s.confirmed { continue }
            byKind[kind, default: [:]][brand] = s
        }
        return order.compactMap { kind in
            guard let brands = byKind[kind], brands.count >= 2 else { return nil }
            return (GarmentCategory(rawValue: kind), brands.values.sorted { $0.brand.lowercased() < $1.brand.lowercased() })
        }
    }
}
