import Foundation
import WearIQCore

/// "Like my favourite tee": a garment the shopper owns and likes, measured flat, set
/// against a new garment's chart. The closest size is the one that would sit the same.
///
/// Only charts of garment measurements compare directly; a body chart lists bodies,
/// not clothes.
public enum ReferenceGarment {
    public struct Match: Sendable, Equatable {
        public var size: String
        /// Chart minus reference per dimension both have, cm.
        public var differences: [GarmentDimension: Double]
        /// Weighted root-mean-square difference, cm.
        public var distance: Double
    }

    /// How much each dimension counts: girths decide how a garment sits, lengths less.
    static func weight(_ d: GarmentDimension) -> Double {
        switch d {
        case .chest, .waist, .hip: 1.0
        case .thigh, .shoulderWidth: 0.7
        case .bodyLength, .inseam, .outseam: 0.5
        case .sleeveLength: 0.4
        }
    }

    /// Every size compared, closest first. Empty for body charts or without any shared
    /// girth (lengths alone don't say how a garment sits).
    public static func matches(spec: GarmentSpec, reference: [GarmentDimension: Double]) -> [Match] {
        guard spec.chartKind == .garment else { return [] }
        let girths: Set<GarmentDimension> = [.chest, .waist, .hip, .thigh]
        return spec.sizes.compactMap { size -> Match? in
            var differences: [GarmentDimension: Double] = [:]
            for (d, mine) in reference where mine > 0 {
                if let theirs = size.values[d]?.cm { differences[d] = theirs - mine }
            }
            guard differences.keys.contains(where: girths.contains) else { return nil }
            let total = differences.reduce(0.0) { $0 + weight($1.key) }
            let sum = differences.reduce(0.0) { $0 + weight($1.key) * $1.value * $1.value }
            return Match(size: size.label, differences: differences, distance: (sum / total).squareRoot())
        }
        .sorted { $0.distance < $1.distance }
    }

    /// The closest size, when it is close enough to call it "the same": within 4 cm on
    /// average (a size step is usually 4–6 cm of girth).
    public static func closest(spec: GarmentSpec, reference: [GarmentDimension: Double]) -> Match? {
        guard let best = matches(spec: spec, reference: reference).first, best.distance <= 4 else { return nil }
        return best
    }
}
