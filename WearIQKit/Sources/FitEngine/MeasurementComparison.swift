import Foundation
import WearIQCore

/// Compares two body profiles without mistaking measurement noise for real change.
public enum MeasurementComparison {
    public enum Trend: String, Codable, Sendable {
        case increased, decreased
        /// The difference is within what the two measurements' uncertainty explains.
        case withinMeasurementError
    }

    public struct Change: Hashable, Sendable {
        public var dimension: BodyDimension
        public var before: MeasuredValue
        public var after: MeasuredValue
        public var deltaCm: Double
        public var trend: Trend
    }

    /// A change counts as real only beyond ~2σ of the combined uncertainty (≈95%),
    /// and never below `minimumCm` (tape measures aren't better than that).
    public static func compare(_ before: BodyProfile, _ after: BodyProfile, minimumCm: Double = 1.5) -> [Change] {
        BodyDimension.allCases.compactMap { d in
            guard d != .height, let b = before[d], let a = after[d] else { return nil }
            let delta = a.cm - b.cm
            let sigma = (b.uncertaintyCm * b.uncertaintyCm + a.uncertaintyCm * a.uncertaintyCm).squareRoot()
            let threshold = max(2 * sigma, minimumCm)
            let trend: Trend = abs(delta) <= threshold ? .withinMeasurementError : (delta > 0 ? .increased : .decreased)
            return Change(dimension: d, before: b, after: a, deltaCm: delta, trend: trend)
        }
    }

    public struct GarmentImpact: Hashable, Sendable {
        public var before: FitAnalysis
        public var after: FitAnalysis
        /// Regions of the previously recommended (or worn) size whose verdict changed.
        public var changedRegions: [(region: FitRegion, from: FitVerdict, to: FitVerdict)]
        public var recommendationChanged: Bool

        public static func == (a: Self, b: Self) -> Bool {
            a.before == b.before && a.after == b.after && a.recommendationChanged == b.recommendationChanged
        }
        public func hash(into h: inout Hasher) { h.combine(before); h.combine(after) }
    }

    /// Re-runs the fit for one garment with the new profile. Only verdict changes on
    /// regions whose body measurement changed beyond measurement error are reported.
    public static func impact(of garment: GarmentSpec, size: String?, before: BodyProfile, after: BodyProfile,
                              preference: FitPreference = .asDesigned, engine: FitEngine = FitEngine()) -> GarmentImpact? {
        let real = Set(compare(before, after).filter { $0.trend != .withinMeasurementError }.map(\.dimension))
        guard !real.isEmpty else { return nil }

        let old = engine.analyze(body: before, garment: garment, preference: preference)
        let new = engine.analyze(body: after, garment: garment, preference: preference)
        let label = size ?? old.recommendedSize?.label
        guard let label, let o = old.sizes.first(where: { $0.label == label }),
              let n = new.sizes.first(where: { $0.label == label }) else { return nil }

        let changed = o.regions.compactMap { r -> (FitRegion, FitVerdict, FitVerdict)? in
            guard let nr = n.region(r.region), nr.verdict != r.verdict,
                  let dim = bodyDimension(for: r.region), real.contains(dim) else { return nil }
            return (r.region, r.verdict, nr.verdict)
        }
        let recommendationChanged = old.recommendation != new.recommendation
        guard !changed.isEmpty || recommendationChanged else { return nil }
        return GarmentImpact(before: old, after: new, changedRegions: changed.map { ($0.0, $0.1, $0.2) },
                             recommendationChanged: recommendationChanged)
    }

    static func bodyDimension(for region: FitRegion) -> BodyDimension? {
        switch region {
        case .shoulder: .shoulderWidth
        case .sleeve: .armLength
        case .chest: .chest
        case .waist: .waist
        case .bodyLength: .torsoLength
        case .hip: .hip
        case .thigh: .thigh
        case .inseam: .inseam
        case .outseam: .outseam
        }
    }
}
