import FitEngine
import Foundation
import ProductMeasurementParser
import WearIQCore

/// The size passport: the user's sizes in the usual systems, worked out from their body
/// with typical size charts (letters for tops, waist/length for jeans, the region's
/// numbers for women's clothes and men's trousers), and how sizes compare from brand to brand from what they
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
        /// European numbers, Turkey's too: women's 34–46, men's trousers 44–58.
        case european
        /// US women's numbers (0–16).
        case us
        /// Jeans: waist and length in inches (31/32).
        case waistLength
    }

    /// The user's sizes in their region's systems (Profile → Size system): letters for
    /// tops everywhere, W/L for jeans everywhere, and the region's numbers for women's
    /// dresses, skirts and trousers and for men's non-denim trousers.
    public static func lines(for body: BodyProfile, region: SizeRegion = .eu) -> [Line] {
        let female = body.sex == .female
        let audience: GarmentAudience = female ? .women : .men
        func ladder(_ c: GarmentCategory, denim: Bool = false) -> [String] {
            SizeSystems.ladder(for: c, audience: audience, region: region, productName: denim ? "jean" : nil)
        }
        let numbers: System = region == .us ? .us : .european
        var plan: [(GarmentCategory, System, [String])] = [
            (.tshirt, .letters, ladder(.tshirt)), (.shirt, .letters, ladder(.shirt)), (.sweater, .letters, ladder(.sweater)),
            (.jacket, .letters, ladder(.jacket)),
        ]
        if female {
            plan += [(.dress, .letters, ladder(.tshirt)), (.dress, numbers, ladder(.dress)), (.skirt, numbers, ladder(.skirt)),
                     (.pants, numbers, ladder(.pants)), (.pants, .waistLength, ladder(.pants, denim: true))]
        } else {
            plan.append((.pants, .waistLength, ladder(.pants, denim: true)))
            if region != .us { plan.append((.pants, .european, ladder(.pants))) }
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
