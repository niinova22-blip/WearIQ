import Foundation
import WearIQCore

/// The reasons behind a size, in one line: "Waist fits · hips roomy · inseam 4 cm longer
/// than your favourite jeans". What decided the size comes first (the waist of trousers,
/// the chest of a top), then what is off, then how it compares with a garment the user
/// owns and likes, which says what the body alone can't: how long they like a leg.
public enum DecisionSummary {
    public enum Part: Equatable, Sendable {
        /// How the size sits in a region of the body.
        case region(FitRegion, FitVerdict)
        /// This size minus the favourite garment, cm (a positive inseam is longer).
        case versusFavourite(GarmentDimension, Double)
    }

    /// At most `limit` parts for `size` of a garment of `category`. `sizeValues` are the
    /// size's own garment measurements (garment charts only) and `favourite` those of the
    /// user's favourite garment of the kind; differences under 1 cm are left out.
    public static func parts(size: SizeFit, category: GarmentCategory, fit: FitStyle = .regular, leg: LegCut? = nil,
                             sizeValues: [GarmentDimension: Double]? = nil,
                             favourite: [GarmentDimension: Double]? = nil, limit: Int = 4) -> [Part] {
        let rules = EaseTable.rules(for: category, fit: fit, leg: leg)
        let critical = Set(rules.filter(\.critical).map(\.region))
        let order = rules.map(\.region)
        let judged = size.regions.filter { $0.verdict != .insufficientData }
        func rank(_ r: RegionFit) -> (Int, Int, Int) {
            (critical.contains(r.region) ? 0 : 1,
             // What is off before what is fine, the worse first.
             r.severity == .major ? 0 : r.severity == .minor ? 1 : 2,
             order.firstIndex(of: r.region) ?? order.count)
        }
        var regions = judged.sorted { rank($0) < rank($1) }
        // The deciding region always; the rest only when they say something, or to fill
        // a line that has nothing else.
        let deciding = regions.filter { critical.contains($0.region) }
        let others = regions.filter { !critical.contains($0.region) }
        let telling = others.filter { $0.severity != .good }
        regions = deciding + (telling.isEmpty ? Array(others.prefix(1)) : telling)

        var favouriteParts: [Part] = []
        if let sizeValues, let favourite {
            // Lengths and the rise first: they are taste, and only a garment says it.
            let dims: [GarmentDimension] = category.isBottom
                ? [.inseam, .frontRise, .outseam, .legOpening, .waist, .hip, .thigh]
                : [.bodyLength, .sleeveLength, .chest, .shoulderWidth, .waist]
            for d in dims {
                guard let mine = favourite[d], mine > 0, let theirs = sizeValues[d] else { continue }
                let delta = (theirs - mine).rounded()
                if abs(delta) >= 1 { favouriteParts.append(.versusFavourite(d, delta)) }
            }
        }
        let favouriteShown = Array(favouriteParts.prefix(limit > 2 ? 2 : 1))
        let regionParts = regions.prefix(max(1, limit - favouriteShown.count)).map { Part.region($0.region, $0.verdict) }
        return Array((regionParts + favouriteShown).prefix(limit))
    }
}
