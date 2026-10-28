import WearIQCore

/// Comfort ranges ("ease") per region. For girths and widths this is garment minus body;
/// for lengths it is garment length minus the matching body length.
///
/// These values are starting heuristics from standard pattern-making ease allowances.
/// They MUST be tuned against the validation dataset (see docs/VALIDATION.md) before
/// any accuracy claims are made.
struct RegionRule {
    enum Kind { case girth, width, length }

    let region: FitRegion
    let kind: Kind
    let garment: GarmentDimension
    let body: BodyDimension
    let weight: Double
    let critical: Bool
    /// Comfortable ease range for a garment-measurement chart.
    let ease: ClosedRange<Double>
    /// Tolerance (±) when the chart lists body measurements instead of garment ones.
    let bodyChartTolerance: Double

    /// Beyond this many cm outside the range a mismatch is "major" rather than "minor".
    var majorThreshold: Double {
        switch kind {
        case .girth: 4
        case .width: 2
        case .length: 3
        }
    }
}

enum EaseTable {
    static func rules(for category: GarmentCategory, fit: FitStyle) -> [RegionRule] {
        switch category {
        case .shirt, .tshirt, .jacket: topRules(category, fit)
        case .pants: pantsRules(fit)
        }
    }

    private static func topRules(_ c: GarmentCategory, _ f: FitStyle) -> [RegionRule] {
        let chestEase: ClosedRange<Double> = switch f {
        case .slim: 5...10
        case .regular: 9...16
        case .relaxed: 14...24
        case .oversized: 22...40
        }
        let waistEase: ClosedRange<Double> = switch f {
        case .slim: 4...12
        case .regular: 8...20
        case .relaxed: 14...30
        case .oversized: 22...50
        }
        let shoulderEase: ClosedRange<Double> = switch f {
        case .slim: -1.5...1.5
        case .regular: -1...2.5
        case .relaxed: 0...4
        case .oversized: 3...12 // dropped shoulders are intentional
        }
        let sleeveEase: ClosedRange<Double> = c == .jacket ? 0...3 : 1...4
        let lengthEase: ClosedRange<Double> = switch c {
        case .tshirt: 12...24
        case .jacket: 18...32
        default: 15...28
        }

        var rules: [RegionRule] = [
            .init(region: .shoulder, kind: .width, garment: .shoulderWidth, body: .shoulderWidth,
                  weight: f == .oversized ? 0.3 : 1.0, critical: false, ease: shoulderEase, bodyChartTolerance: 1.5),
            .init(region: .chest, kind: .girth, garment: .chest, body: .chest,
                  weight: 1.0, critical: true, ease: chestEase, bodyChartTolerance: 2.5),
            .init(region: .waist, kind: .girth, garment: .waist, body: .waist,
                  weight: 0.5, critical: false, ease: waistEase, bodyChartTolerance: 2.5),
            .init(region: .bodyLength, kind: .length, garment: .bodyLength, body: .torsoLength,
                  weight: 0.3, critical: false, ease: lengthEase, bodyChartTolerance: 3),
        ]
        // T-shirt sleeves are short by design; arm length is irrelevant there.
        if c != .tshirt {
            rules.insert(.init(region: .sleeve, kind: .length, garment: .sleeveLength, body: .armLength,
                               weight: 0.4, critical: false, ease: sleeveEase, bodyChartTolerance: 2), at: 1)
        }
        return rules
    }

    private static func pantsRules(_ f: FitStyle) -> [RegionRule] {
        let hipEase: ClosedRange<Double> = switch f {
        case .slim: 2...6
        case .regular: 4...10
        case .relaxed: 8...16
        case .oversized: 14...30
        }
        let thighEase: ClosedRange<Double> = switch f {
        case .slim: 3...7
        case .regular: 6...12
        case .relaxed: 10...20
        case .oversized: 16...32
        }
        return [
            .init(region: .waist, kind: .girth, garment: .waist, body: .waist,
                  weight: 1.0, critical: true, ease: 0...3, bodyChartTolerance: 2),
            .init(region: .hip, kind: .girth, garment: .hip, body: .hip,
                  weight: 0.9, critical: false, ease: hipEase, bodyChartTolerance: 2.5),
            .init(region: .thigh, kind: .girth, garment: .thigh, body: .thigh,
                  weight: 0.6, critical: false, ease: thighEase, bodyChartTolerance: 2.5),
            .init(region: .inseam, kind: .length, garment: .inseam, body: .inseam,
                  weight: 0.5, critical: false, ease: -3...1, bodyChartTolerance: 2),
            .init(region: .outseam, kind: .length, garment: .outseam, body: .outseam,
                  weight: 0.3, critical: false, ease: -3...1, bodyChartTolerance: 2),
        ]
    }
}
