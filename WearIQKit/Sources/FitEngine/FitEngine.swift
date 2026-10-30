import Foundation
import WearIQCore

public protocol FitAnalyzing: Sendable {
    func analyze(body: BodyProfile, garment: GarmentSpec, preference: FitPreference) -> FitAnalysis
}

/// Compares a body profile against every size of a garment and recommends one.
///
/// Every verdict comes from arithmetic on the actual measurements; nothing is hard-coded.
/// Measurement uncertainty is propagated by integrating the penalty over a normal
/// distribution of the true ease (Gauss–Hermite quadrature).
public struct FitEngine: FitAnalyzing {
    /// When the two best sizes' penalties are this close, we say "between sizes".
    public var betweenSizesMargin: Double = 0.08

    public init() {}

    public func analyze(body: BodyProfile, garment: GarmentSpec, preference: FitPreference = .asDesigned) -> FitAnalysis {
        let rules = EaseTable.rules(for: garment.category, fit: garment.fitStyle)
        let sizes = garment.sizes.map { evaluate(size: $0, body: body, garment: garment, rules: rules, preference: preference) }
        return FitAnalysis(recommendation: recommend(sizes: sizes, rules: rules), sizes: sizes)
    }

    // MARK: - Per size

    private func evaluate(size: SizeEntry, body: BodyProfile, garment: GarmentSpec, rules: [RegionRule], preference: FitPreference) -> SizeFit {
        var regions: [RegionFit] = []
        var penalty = 0.0
        var hasCritical = true

        for rule in rules {
            guard let b = rule.region == .shoulder ? body[.shoulderWidth].map(Self.acrossBack) : body[rule.body] else {
                regions.append(.missing(rule.region, .bodyMeasurement))
                if rule.critical { hasCritical = false }
                continue
            }
            guard let g = size.values[rule.garment] else {
                regions.append(.missing(rule.region, .garmentMeasurement))
                if rule.critical { hasCritical = false }
                continue
            }
            let (fit, p) = evaluate(rule: rule, body: b, garment: g, spec: garment, preference: preference)
            regions.append(fit)
            penalty += p
        }
        return SizeFit(label: size.label, regions: regions, penalty: penalty, hasCriticalData: hasCritical)
    }

    private func evaluate(rule: RegionRule, body b: MeasuredValue, garment g: MeasuredValue, spec: GarmentSpec, preference: FitPreference) -> (RegionFit, Double) {
        let range: ClosedRange<Double>
        let sigma: Double
        switch spec.chartKind {
        case .garment:
            range = adjustedEase(rule, body: b.cm, spec: spec, preference: preference)
            sigma = (b.uncertaintyCm * b.uncertaintyCm + g.uncertaintyCm * g.uncertaintyCm).squareRoot()
        case .body:
            // The chart states which body a size fits; a range in the chart widens tolerance.
            let tol = rule.bodyChartTolerance + g.uncertaintyCm
            let shift = preferenceShift(preference, width: 2 * tol, kind: rule.kind)
            range = (-tol + shift)...(tol + rule.bodyChartLooseAllowance + shift)
            sigma = b.uncertaintyCm
        }

        let ease = g.cm - b.cm
        let outside = Self.outside(ease, range)
        let verdict = Self.verdict(outside: outside, rule: rule)
        let severity: FitSeverity = outside == 0 ? .good : (abs(outside) > rule.majorThreshold ? .major : .minor)

        let pIdeal = Self.normalCDF((range.upperBound - ease) / max(sigma, 0.01))
            - Self.normalCDF((range.lowerBound - ease) / max(sigma, 0.01))

        var offset: ClosedRange<Double>?
        if outside != 0 {
            // A body chart's length is the body the size suits, so the useful number is the
            // whole difference ("about 6 cm longer than your leg"), not the part beyond the
            // tolerance.
            let m = spec.chartKind == .body && rule.kind == .length ? abs(ease) : abs(outside)
            offset = max(0, m - sigma)...(m + sigma)
        }

        // Confidence: how sure are we about the verdict, given the uncertainty?
        let decisive = outside == 0 ? pIdeal : 1 - pIdeal
        let confidence: ConfidenceLevel = decisive > 0.8 ? .high : (decisive > 0.6 ? .medium : .low)

        let expected = Self.expectedPenalty(ease: ease, sigma: sigma, range: range, rule: rule)
        var fit = RegionFit(region: rule.region, verdict: verdict, severity: severity,
                            estimatedOffsetCm: offset, probabilityIdeal: pIdeal,
                            confidence: confidence, missing: nil)
        fit.easeCm = ease
        return (fit, rule.weight * expected)
    }

    private func adjustedEase(_ rule: RegionRule, body: Double, spec: GarmentSpec, preference: FitPreference) -> ClosedRange<Double> {
        var lo = rule.ease.lowerBound
        var hi = rule.ease.upperBound
        if rule.kind == .girth {
            // Stretch lets a garment be worn smaller than the body without discomfort.
            lo -= spec.stretch.comfortableStretch * body
            // Thick fabric eats into the available room.
            lo += spec.thickness.extraEaseCm
            hi += spec.thickness.extraEaseCm
        }
        let shift = preferenceShift(preference, width: hi - lo, kind: rule.kind)
        return (lo + shift)...(hi + shift)
    }

    private func preferenceShift(_ p: FitPreference, width: Double, kind: RegionRule.Kind) -> Double {
        // Length preference is about drape, not tightness; leave lengths alone.
        guard kind != .length else { return 0 }
        switch p {
        case .snugger: return -0.35 * width
        case .asDesigned: return 0
        case .looser: return 0.35 * width
        }
    }

    /// Shoulder width as a garment chart measures it: across the back from one shoulder
    /// point to the other, over the curve of the back. A tape measurement (the app asks
    /// for exactly that) is already this. A scan or an estimate gives biacromial breadth,
    /// the straight distance between the shoulder bones, which runs about 8.5% shorter:
    /// in ANSUR II the over-the-back interscye breadth averages 45.0 cm on men with a
    /// 41.6 cm biacromial breadth, and 39.6 on women with 36.5 (ratios 1.082 and 1.085).
    /// Compared directly, every shirt's shoulders read about 4 cm too wide.
    public static func acrossBack(_ shoulder: MeasuredValue) -> MeasuredValue {
        guard shoulder.source == .scan || shoulder.source == .estimated else { return shoulder }
        let ratio = 1.085
        // The ratio itself varies from person to person, about ±1 cm at these sizes.
        let sd = ((shoulder.uncertaintyCm * ratio) * (shoulder.uncertaintyCm * ratio) + 1).squareRoot()
        return MeasuredValue(cm: shoulder.cm * ratio, uncertaintyCm: sd, source: shoulder.source)
    }

    // MARK: - Recommendation

    private func recommend(sizes: [SizeFit], rules: [RegionRule]) -> SizeRecommendation {
        let usable = sizes.enumerated().filter { $0.element.hasCriticalData }
        guard let best = usable.min(by: { $0.element.penalty < $1.element.penalty }) else {
            let missing = rules.filter(\.critical).map(\.region)
            return .insufficientData(missing: missing)
        }

        // Neighbouring size almost as good → be honest that it's a toss-up.
        let neighbours = usable.filter { abs($0.offset - best.offset) == 1 }
        if let close = neighbours.min(by: { $0.element.penalty < $1.element.penalty }),
           close.element.penalty - best.element.penalty < betweenSizesMargin {
            let (s, l) = close.offset < best.offset ? (close.element, best.element) : (best.element, close.element)
            return .between(smaller: s.label, larger: l.label)
        }

        let measured = best.element.regions.filter { $0.verdict != .insufficientData }
        let criticalRegions = Set(rules.filter(\.critical).map(\.region))
        let criticalConfidence = measured.filter { criticalRegions.contains($0.region) }.map(\.confidence).min() ?? .low
        let coverage = Double(measured.count) / Double(max(rules.count, 1))
        var confidence = criticalConfidence
        if coverage < 0.6 { confidence = min(confidence, .medium) }
        if coverage < 0.4 { confidence = .low }
        return .size(label: best.element.label, confidence: confidence)
    }

    // MARK: - Math

    /// Signed distance outside the range: negative = too small, positive = too big, 0 = inside.
    static func outside(_ x: Double, _ r: ClosedRange<Double>) -> Double {
        if x < r.lowerBound { return x - r.lowerBound }
        if x > r.upperBound { return x - r.upperBound }
        return 0
    }

    static func verdict(outside: Double, rule: RegionRule) -> FitVerdict {
        if outside == 0 { return .ideal }
        if rule.kind == .length { return outside < 0 ? .short : .long }
        let major = abs(outside) > rule.majorThreshold
        if outside < 0 { return major ? .tight : .slightlyTight }
        return major ? .loose : .slightlyLoose
    }

    /// Penalty for a given true ease. Too small is worse than too big for girths/widths
    /// because a tight garment can't be fixed; for lengths, too short is worse.
    static func penalty(ease: Double, range: ClosedRange<Double>, rule: RegionRule) -> Double {
        let o = outside(ease, range)
        guard o != 0 else { return 0 }
        let scaled = abs(o) / rule.majorThreshold
        let asymmetry = o < 0 ? 1.6 : 1.0
        return asymmetry * scaled * scaled
    }

    // 5-point Gauss–Hermite nodes/weights for E[f(X)], X ~ N(μ, σ²).
    private static let ghNodes: [Double] = [-2.0201828705, -0.9585724646, 0, 0.9585724646, 2.0201828705]
    private static let ghWeights: [Double] = [0.0199532421, 0.3936193232, 0.9453087205, 0.3936193232, 0.0199532421]

    static func expectedPenalty(ease: Double, sigma: Double, range: ClosedRange<Double>, rule: RegionRule) -> Double {
        guard sigma > 0 else { return penalty(ease: ease, range: range, rule: rule) }
        var sum = 0.0
        for (x, w) in zip(ghNodes, ghWeights) {
            sum += w * penalty(ease: ease + 2.0.squareRoot() * sigma * x, range: range, rule: rule)
        }
        return sum / Double.pi.squareRoot()
    }

    static func normalCDF(_ z: Double) -> Double {
        0.5 * erfc(-z / 2.0.squareRoot())
    }
}

private extension RegionFit {
    static func missing(_ region: FitRegion, _ what: MissingData) -> RegionFit {
        RegionFit(region: region, verdict: .insufficientData, severity: .unknown,
                  estimatedOffsetCm: nil, probabilityIdeal: nil, confidence: .low, missing: what)
    }
}
