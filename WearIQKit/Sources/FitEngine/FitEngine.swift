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
        let rules = EaseTable.rules(for: garment.category, fit: garment.fitStyle, leg: garment.legCut)
        let sizes = garment.sizes.map { evaluate(size: $0, body: body, garment: garment, rules: rules, preference: preference) }
        var analysis = FitAnalysis(recommendation: recommend(sizes: sizes, rules: rules), sizes: sizes)
        let critical = rules.filter(\.critical)
        if let rule = critical.first, analysis.recommendedSize != nil,
           !sizes.contains(where: { s in s.region(rule.region).map { $0.verdict != .tight && $0.verdict != .loose } ?? false }) {
            analysis.noSizeFits = rule.region
        }
        if critical.contains(where: { body[$0.body]?.source == .estimated }) { analysis.fromEstimates = true }
        analysis.recommendation = settled(analysis.recommendation, body: body, garment: garment, rules: rules,
                                          preference: preference)
        return analysis
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
            // A short or elbow sleeve is short by design, not too short: Koton's short-
            // sleeved dress (13.5 cm sleeve) was sent two sizes up for "longer" sleeves.
            if rule.garment == .sleeveLength, garment.chartKind == .garment, g.cm < 0.6 * b.cm { continue }
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
            // The chart states which body a size fits; a range in the chart widens a girth's
            // tolerance. A length is one body length per size: how sure it is (a length
            // read off the model's photo, ±3.5 cm) is uncertainty, not room, or every size
            // from S to 2XL has "ideal" sleeves.
            if rule.kind == .length {
                let tol = rule.bodyChartTolerance
                range = -tol...tol
                sigma = (b.uncertaintyCm * b.uncertaintyCm + g.uncertaintyCm * g.uncertaintyCm).squareRoot()
            } else {
                // A chart value's spread is partly the size's own range (M: chest 96–104)
                // and partly how far the brand may run from it (about 2 cm, the extra a
                // standard chart carries). The range is room; the brand's drift is doubt.
                // Counting both as room made a standard chart's sizes ±8.5 cm wide, and a
                // 103 cm chest "slightly tight" in a size for 92.
                let drift = min(g.uncertaintyCm, 2)
                let tol = rule.bodyChartTolerance + g.uncertaintyCm - drift
                let shift = preferenceShift(preference, width: 2 * tol, kind: rule.kind)
                range = (-tol + shift)...(tol + rule.bodyChartLooseAllowance + shift)
                sigma = (b.uncertaintyCm * b.uncertaintyCm + drift * drift).squareRoot()
            }
        }

        let ease = g.cm - b.cm
        let outside = Self.outside(ease, range)
        var verdict = Self.verdict(outside: outside, rule: rule)
        var severity: FitSeverity = outside == 0 ? .good : (abs(outside) > rule.majorThreshold ? .major : .minor)
        // Outside the cut's range but with an everyday fit's room: slight, said as such.
        var comfort: ClosedRange<Double>?
        if spec.chartKind == .garment, let c = rule.comfort {
            comfort = (c.lowerBound + range.lowerBound - rule.ease.lowerBound)...(c.upperBound + range.upperBound - rule.ease.upperBound)
        }
        let byCutOnly = outside != 0 && comfort?.contains(ease) == true
        if byCutOnly {
            verdict = outside < 0 ? .slightlyTight : .slightlyLoose
            severity = .minor
        }

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
        var confidence: ConfidenceLevel = decisive > 0.8 ? .high : (decisive > 0.6 ? .medium : .low)
        // A body known only from height and weight is a population's average for them: the
        // people it stands for differ by a size either way. Advice from it is never sure;
        // of 776 garments checked on 400 shoppers it named a different size from the tape
        // a third of the time while calling itself sure (docs/VALIDATION.md §15).
        if b.source == .estimated { confidence = min(confidence, .medium) }

        let expected = Self.expectedPenalty(ease: ease, sigma: sigma, range: range, rule: rule, comfort: comfort)
        var fit = RegionFit(region: rule.region, verdict: verdict, severity: severity,
                            estimatedOffsetCm: offset, probabilityIdeal: pIdeal,
                            confidence: confidence, missing: nil)
        fit.easeCm = ease
        // Wearable: within the range, or out of it by no more than a slight miss (the
        // comfort range of an everyday fit counts as slight too).
        let lo = min(range.lowerBound - rule.majorThreshold, comfort?.lowerBound ?? .infinity)
        let hi = max(range.upperBound + rule.majorThreshold, comfort?.upperBound ?? -.infinity)
        fit.probabilityWearable = Self.normalCDF((hi - ease) / max(sigma, 0.01)) - Self.normalCDF((lo - ease) / max(sigma, 0.01))
        if byCutOnly { fit.byCutOnly = true }
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

    /// How sure a size is, is how sure it is to stay the best: a size whose every region
    /// is surely right can still be the wrong pick if a body a little off the measured
    /// one would be better in the next size. The deciding measurements (chest for a top,
    /// waist for trousers) are moved by their own uncertainty both ways and the
    /// recommendation found again: if it changes within 0.6 σ the advice is unsure, within
    /// 1.6 σ at most fairly sure. A scan's chest is good to ±2.5 cm, which is a third of a
    /// size step, and without this a fifth of "sure" sizes from a scan were not the size
    /// the tape gives (docs/VALIDATION.md §15).
    private func settled(_ rec: SizeRecommendation, body: BodyProfile, garment: GarmentSpec, rules: [RegionRule],
                         preference: FitPreference) -> SizeRecommendation {
        guard case let .size(label, confidence) = rec, confidence > .low else { return rec }
        let dims = rules.filter(\.critical).map(\.body)
        func pick(_ k: Double) -> String? {
            var moved = body
            for d in dims {
                guard let v = body[d] else { continue }
                moved[d] = MeasuredValue(cm: v.cm + k * v.uncertaintyCm, uncertaintyCm: v.uncertaintyCm, source: v.source)
            }
            let sizes = garment.sizes.map { evaluate(size: $0, body: moved, garment: garment, rules: rules, preference: preference) }
            switch recommend(sizes: sizes, rules: rules) {
            case let .size(l, _): return l
            case let .between(a, b): return a == label || b == label ? label : a
            case .insufficientData: return nil
            }
        }
        if pick(-0.6) != label || pick(0.6) != label { return .size(label: label, confidence: .low) }
        if confidence == .high, pick(-1.6) != label || pick(1.6) != label { return .size(label: label, confidence: .medium) }
        return rec
    }

    private func recommend(sizes: [SizeFit], rules: [RegionRule]) -> SizeRecommendation {
        let criticalRegions = Set(rules.filter(\.critical).map(\.region))
        var usable = sizes.enumerated().filter { $0.element.hasCriticalData }
        // A size that fits where it matters (the chest of a top, the waist of trousers)
        // beats one that doesn't, however the rest adds up: a chest you can't close, or a
        // waistband that falls down, isn't made up for by sleeves the right length.
        func fitsWhereItMatters(_ s: SizeFit) -> Bool {
            s.regions.filter { criticalRegions.contains($0.region) }
                .allSatisfy { $0.verdict != .tight && $0.verdict != .loose }
        }
        let fitting = usable.filter { fitsWhereItMatters($0.element) }
        if !fitting.isEmpty { usable = fitting }
        guard let best = usable.min(by: { $0.element.penalty < $1.element.penalty }) else {
            let missing = rules.filter(\.critical).map(\.region)
            return .insufficientData(missing: missing)
        }

        // No size fits where it matters (a body beyond the chart's ends): the nearest one
        // is named, but never with confidence.
        if fitting.isEmpty { return .size(label: best.element.label, confidence: .low) }

        // Neighbouring size almost as good → be honest that it's a toss-up.
        let neighbours = usable.filter { abs($0.offset - best.offset) == 1 }
        if let close = neighbours.min(by: { $0.element.penalty < $1.element.penalty }),
           close.element.penalty - best.element.penalty < betweenSizesMargin {
            let (s, l) = close.offset < best.offset ? (close.element, best.element) : (best.element, close.element)
            return .between(smaller: s.label, larger: l.label)
        }

        let measured = best.element.regions.filter { $0.verdict != .insufficientData }
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
    /// because a tight garment can't be fixed; for lengths, too short is worse. Less room
    /// than the cut has but still an everyday fit's (`comfort`) is only a style miss.
    /// Shoulders too wide only drop the seams down the arm, which is far less than a
    /// tight chest: a broad chest on narrow shoulders needs the size its chest needs.
    static func penalty(ease: Double, range: ClosedRange<Double>, rule: RegionRule,
                        comfort: ClosedRange<Double>? = nil) -> Double {
        let o = outside(ease, range)
        guard o != 0 else { return 0 }
        let scaled = abs(o) / rule.majorThreshold
        let asymmetry: Double
        if o < 0 {
            asymmetry = comfort?.contains(ease) == true ? 1.0 : 1.6
        } else {
            asymmetry = rule.loosePenalty
        }
        return asymmetry * scaled * scaled
    }

    // 5-point Gauss–Hermite nodes/weights for E[f(X)], X ~ N(μ, σ²).
    private static let ghNodes: [Double] = [-2.0201828705, -0.9585724646, 0, 0.9585724646, 2.0201828705]
    private static let ghWeights: [Double] = [0.0199532421, 0.3936193232, 0.9453087205, 0.3936193232, 0.0199532421]

    static func expectedPenalty(ease: Double, sigma: Double, range: ClosedRange<Double>, rule: RegionRule,
                                comfort: ClosedRange<Double>? = nil) -> Double {
        guard sigma > 0 else { return penalty(ease: ease, range: range, rule: rule, comfort: comfort) }
        var sum = 0.0
        for (x, w) in zip(ghNodes, ghWeights) {
            sum += w * penalty(ease: ease + 2.0.squareRoot() * sigma * x, range: range, rule: rule, comfort: comfort)
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
