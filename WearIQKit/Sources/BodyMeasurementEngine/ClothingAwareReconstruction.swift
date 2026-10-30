import Foundation
import WearIQCore

/// What the user said they wear for the scan, before it starts.
public enum ScanAttire: String, Codable, CaseIterable, Sendable {
    /// Underwear, sportswear, leggings, a fitted T-shirt.
    case fitted
    /// Whatever they have on: T-shirt, shirt, trousers.
    case everyday
}

/// Separates the clothes' outline from the body under it.
///
/// The turn measures the girth of the outline, which is the body plus whatever the
/// clothes add there. How much they add is unknown, so it's treated as a random amount
/// whose size depends on how the clothes sit (`ClothingCover`), and the body is found by
/// Bayes' rule from three things:
///
/// - the outline girth, with the scan's own error (3%, from the ANSUR validation);
/// - what the clothes add, for each kind of cover (`EaseModel`), weighted by how likely
///   each kind is (what the user said they wear, and the loose-clothing checks);
/// - what the body is likely to be anyway: a recent trusted measurement of this person,
///   or else the height/weight statistics (`AnthropometricPrior`).
///
/// No fixed amount is ever subtracted. With fitted clothes the outline dominates and
/// the result stays as sharp as before; with a loose top, an outline far above the
/// statistics is explained by the clothes, the body falls back towards the statistics
/// and the range widens accordingly, so a waist the clothes hid comes out with low
/// confidence rather than a confident wrong number. Lengths and the shoulder breadth
/// come from the skeleton, which clothes barely move, and are left as they are.
public struct ClothingAwareReconstruction: Sendable {
    /// What a kind of cover adds to a girth, as a fraction of the body girth: normal with
    /// this mean and SD.
    ///
    /// Starting values, not yet calibrated against paired tape measurements (see
    /// docs/VALIDATION.md, "Clothed scans"): skin and fitted from stretch fabric's
    /// thickness and slight compression; regular to layered bracket the design ease of
    /// regular, relaxed and oversized tops in `EaseTable` (chest 9–16, 14–24, 22–40 cm on
    /// a ~100 cm chest), less the part that rests on the shoulders and chest and doesn't
    /// show in the outline, and agree with the two device scans in clothes we have (a
    /// loose T-shirt: waist +10 cm on 84; a sweater: +13, +15, +7 cm on chest, waist,
    /// hips).
    public struct EaseModel: Sendable {
        public var mean: Double
        public var sd: Double
        public init(mean: Double, sd: Double) { self.mean = mean; self.sd = sd }
    }

    public var ease: [ClothingCover: EaseModel] = [
        .skin: EaseModel(mean: 0.003, sd: 0.008),
        .fitted: EaseModel(mean: 0.015, sd: 0.015),
        .regular: EaseModel(mean: 0.07, sd: 0.04),
        .slightlyLoose: EaseModel(mean: 0.11, sd: 0.05),
        .loose: EaseModel(mean: 0.17, sd: 0.07),
        .layered: EaseModel(mean: 0.22, sd: 0.08),
    ]

    /// Relative error of an outline girth from the turn (ANSUR II: mean absolute error
    /// 1.0–1.2%, 95th percentile 2.4–2.9% → SD ≈ 1.5%, doubled for real photos).
    public var outlineRelError = 0.03

    public init() {}

    /// How likely each kind of cover is before looking at the measurements.
    public static func coverPrior(attire: ScanAttire?, region: ClothingRegion) -> [ClothingCover: Double] {
        switch attire {
        case .fitted:
            return [.skin: 0.3, .fitted: 0.55, .regular: 0.1, .slightlyLoose: 0.04, .loose: 0.01, .layered: 0]
        case .everyday:
            // Trousers sit closer at the hips and thighs than a top does at the waist.
            if region == .hips || region == .legs {
                return [.skin: 0.02, .fitted: 0.2, .regular: 0.45, .slightlyLoose: 0.2, .loose: 0.1, .layered: 0.03]
            }
            return [.skin: 0.02, .fitted: 0.13, .regular: 0.4, .slightlyLoose: 0.25, .loose: 0.14, .layered: 0.06]
        case nil:
            return [.skin: 0.15, .fitted: 0.35, .regular: 0.25, .slightlyLoose: 0.13, .loose: 0.08, .layered: 0.04]
        }
    }

    /// The loose-clothing checks shift the odds towards looser cover where they fired.
    public static func applying(_ findings: [ClothingCheck.Finding], to prior: [ClothingCover: Double],
                                region: ClothingRegion) -> [ClothingCover: Double] {
        let hit = findings.contains { finding in
            switch finding {
            case .looseTop: region == .chest || region == .waist
            case .looseSleeves: region == .arms
            }
        }
        guard hit else { return prior }
        // The checks are tuned to fire on less than 0.5% of bodies, so a hit is strong
        // evidence of loose cover there.
        let boost: [ClothingCover: Double] = [.skin: 0.05, .fitted: 0.2, .regular: 1, .slightlyLoose: 3, .loose: 5, .layered: 5]
        return Self.normalised(prior.mapValues { $0 }.merging(boost) { $0 * $1 })
    }

    /// The body under one outline girth.
    public struct Estimate: Equatable, Sendable {
        public var value: MeasuredValue
        public var assessment: MeasurementAssessment
        /// How likely each kind of cover is after seeing the outline.
        public var cover: [ClothingCover: Double]

        public var likeliestCover: ClothingCover {
            cover.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? .fitted
        }
    }

    /// - Parameters:
    ///   - outline: the girth the scan measured, cm.
    ///   - expected: what the body is likely to be without looking (statistics or an
    ///     earlier trusted measurement), with its SD.
    ///   - coverPrior: how likely each kind of cover is beforehand.
    ///   - outlineError: the outline's own relative error when worse than the turn's
    ///     (a thigh from the front photo alone).
    public func reconstruct(outline: Double, expected: MeasuredValue,
                            coverPrior: [ClothingCover: Double], outlineError: Double? = nil) -> Estimate {
        let outlineRel = max(outlineRelError, outlineError ?? 0)
        let mu = expected.cm, s = max(expected.uncertaintyCm, 0.5)
        // The body can't be larger than the outline by more than the outline's own error,
        // nor implausibly far below either.
        let lo = max(1, min(mu - 5 * s, outline * 0.55)), hi = max(mu + 5 * s, outline * 1.08)
        let n = 600
        let step = (hi - lo) / Double(n - 1)
        let prior = Self.normalised(coverPrior)
        var density = [Double](repeating: 0, count: n)
        var coverMass = [ClothingCover: Double]()
        for i in 0..<n {
            let body = lo + Double(i) * step
            let p = Self.normal(body, mu, s)
            var sum = 0.0
            for (cover, w) in prior where w > 0 {
                guard let e = ease[cover] else { continue }
                // Outline = body·(1 + ease) with the scan's error on top.
                let mean = body * (1 + e.mean)
                let sd = ((body * e.sd) * (body * e.sd) + (outline * outlineRel) * (outline * outlineRel)).squareRoot()
                let l = w * Self.normal(outline, mean, sd)
                sum += l
                coverMass[cover, default: 0] += p * l
            }
            density[i] = p * sum
        }
        let total = density.reduce(0, +)
        guard total > 0 else {
            // The outline is nowhere near anything plausible: trust the expectation.
            return Estimate(value: expected, assessment: MeasurementAssessment(expected), cover: prior)
        }
        var mean = 0.0
        for i in 0..<n { mean += (lo + Double(i) * step) * density[i] }
        mean /= total
        var variance = 0.0
        for i in 0..<n { let d = lo + Double(i) * step - mean; variance += d * d * density[i] }
        variance /= total
        func quantile(_ q: Double) -> Double {
            var acc = 0.0
            for i in 0..<n {
                acc += density[i] / total
                if acc >= q { return lo + Double(i) * step }
            }
            return hi
        }
        let posterior = Self.normalised(coverMass)
        let value = MeasuredValue(cm: mean, uncertaintyCm: variance.squareRoot(), source: .scan)
        let assessment = MeasurementAssessment(low: quantile(0.05), high: quantile(0.95),
                                               clothing: posterior.max { $0.value < $1.value }?.key,
                                               clothingEffectCm: outline - mean)
        return Estimate(value: value, assessment: assessment, cover: posterior)
    }

    // MARK: Whole profile

    /// Replaces the outline girths in a scanned profile with the body under the clothes,
    /// and records range, cover and effect for every value.
    ///
    /// - Parameters:
    ///   - profile: as measured (girths are outline girths).
    ///   - expected: statistics for this height, weight, sex and age.
    ///   - previous: an earlier profile; its manual or tight-clothes values stand in for
    ///     the statistics, widened with the time since and shifted with the weight change.
    public func apply(to profile: BodyProfile, attire: ScanAttire?, findings: [ClothingCheck.Finding],
                      expected: [BodyDimension: MeasuredValue], previous: BodyProfile? = nil,
                      heightCm: Double? = nil, now: Date = Date()) -> BodyProfile {
        var out = profile
        var assessments = profile.assessments ?? [:]
        var regionCover: [ClothingRegion: [ClothingCover: Double]] = [:]
        for d in [BodyDimension.chest, .waist, .hip, .thigh] {
            guard let measured = profile[d], measured.source == .scan, let region = ClothingRegion(d) else { continue }
            var statistics = expected[d]
            if d == .thigh {
                // The thigh goes with the hips and waist beyond what height and weight say;
                // the torso girths just found narrow its estimate (see GirthCorrelations).
                let torso = out.values.filter { [.chest, .waist, .hip].contains($0.key) && $0.value.source != .estimated }
                statistics = AnthropometricPrior.conditioned([.thigh], estimates: expected, observed: torso,
                                                             sex: profile.sex)[.thigh] ?? statistics
            }
            let earlier = previous.flatMap { Self.carriedForward(d, from: $0, weightKg: profile.weightKg,
                                                                heightCm: heightCm ?? profile[.height]?.cm, now: now) }
            guard let reference = earlier ?? statistics else { continue }
            let prior = Self.applying(findings, to: Self.coverPrior(attire: attire, region: region), region: region)
            let estimate = reconstruct(outline: measured.cm, expected: reference, coverPrior: prior,
                                       outlineError: measured.cm > 0 ? measured.uncertaintyCm / measured.cm : nil)
            out[d] = estimate.value
            assessments[d] = estimate.assessment
            regionCover[region] = estimate.cover
        }
        // Girths too small to see come from the statistics, narrowed by the measured ones.
        let measured = out.values.filter { [.chest, .waist, .hip, .thigh].contains($0.key) && $0.value.source != .estimated }
        let details = BodyDimension.details.filter { out[$0] == nil && expected[$0] != nil }
        let conditioned = AnthropometricPrior.conditioned(details, estimates: expected, observed: measured, sex: profile.sex)
        for d in details { out[d] = conditioned[d] ?? expected[d] }
        // Regions without an outline girth keep what was said and checked.
        for region in ClothingRegion.allCases where regionCover[region] == nil {
            regionCover[region] = Self.applying(findings, to: Self.coverPrior(attire: attire, region: region), region: region)
        }
        for (d, v) in out.values where assessments[d] == nil {
            assessments[d] = MeasurementAssessment(v)
        }
        out.assessments = assessments
        out.clothing = regionCover.mapValues { odds in
            odds.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? .fitted
        }
        return out
    }

    /// An earlier value good enough to lean on (by tape, or from a scan in skin-tight or
    /// fitted clothes there), moved by the weight change and widened by the time since.
    ///
    /// Drift: girths change with weight along the statistics' weight slope; what else
    /// changes is unknown, so 0.4 cm of SD is added per month. After two years the
    /// earlier value isn't used.
    static func carriedForward(_ d: BodyDimension, from previous: BodyProfile, weightKg: Double?,
                               heightCm: Double?, now: Date) -> MeasuredValue? {
        guard let v = previous[d] else { return nil }
        let trusted = v.source == .manual
            || (v.source == .scan && [ClothingCover.skin, .fitted].contains(previous.clothing?[ClothingRegion(d) ?? .chest] ?? .fitted)
                && previous.assessments?[d] != nil)
        guard trusted else { return nil }
        let months = max(0, now.timeIntervalSince(previous.createdAt) / (30.4 * 86_400))
        guard months < 24 else { return nil }
        var cm = v.cm
        if let w = weightKg, let w0 = previous.weightKg, let h = heightCm,
           let slope = AnthropometricPrior.weightSlope(d, heightCm: h, sex: previous.sex) {
            cm += slope * (w - w0)
        }
        let sd = (v.uncertaintyCm * v.uncertaintyCm + (0.4 * months) * (0.4 * months)).squareRoot()
        return MeasuredValue(cm: cm, uncertaintyCm: sd, source: .estimated)
    }

    static func normal(_ x: Double, _ mu: Double, _ sd: Double) -> Double {
        let z = (x - mu) / sd
        return exp(-0.5 * z * z) / (sd * (2 * Double.pi).squareRoot())
    }

    static func normalised(_ odds: [ClothingCover: Double]) -> [ClothingCover: Double] {
        let total = odds.values.reduce(0, +)
        return total > 0 ? odds.mapValues { $0 / total } : odds
    }
}

extension AnthropometricPrior {
    /// Centimetres a girth changes per kilogram at this height (the weight and BMI terms).
    public static func weightSlope(_ d: BodyDimension, heightCm: Double, sex: BodySex?) -> Double? {
        guard let m = models[sex]?[d] else { return nil }
        return m.c + m.d / ((heightCm / 100) * (heightCm / 100))
    }
}
