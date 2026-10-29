import Foundation
import WearIQCore

/// Predicts body measurements from height, weight and (optionally) sex.
///
/// Linear models `value = a + b·height + c·weight + d·BMI`, fitted by least squares on
/// the public ANSUR II anthropometric survey (US Army 2012, 4,082 men and 1,986 women;
/// https://www.openlab.psu.edu/ansur2/). Mapping: chest = chest circumference,
/// waist = waist circumference, hip = buttock circumference, thigh = thigh circumference,
/// shoulder = biacromial breadth, arm = acromion–radiale + radiale–stylion,
/// torso = cervicale height − waist (omphalion) height, inseam = crotch height,
/// outseam = waist (omphalion) height.
///
/// The survey population is military and fitter than average, so the in-sample residual
/// SD is inflated by `populationShiftFactor`. Waist and hips, where civilians differ most,
/// are fitted on ANSUR II together with NHANES 2017–March 2020 (CDC, US civilian adults
/// 18–65, 6,456 people; scripts/fit_prior.py) and use their pooled residual SD as is.
/// These are statistical estimates for a typical body of that height and weight, never a
/// measurement of this person.
public struct AnthropometricPrior: Sendable {
    struct Model {
        let a, b, c, d: Double
        /// Residual standard deviation in cm.
        let sd: Double
    }

    public var populationShiftFactor = 1.3
    /// Fitted on military and civilian data together; their SD needs no inflation.
    static let civilianFitted: Set<BodyDimension> = [.waist, .hip]

    public init() {}

    static let models: [BodySex?: [BodyDimension: Model]] = [
        .male: [
            .chest: Model(a: 17.7891, b: 0.1955, c: 0.1214, d: 1.5662, sd: 3.19),
            .waist: Model(a: 47.9172, b: -0.1249, c: 0.4106, d: 1.2382, sd: 5.11),
            .hip: Model(a: -11.5334, b: 0.3761, c: -0.0005, d: 1.7201, sd: 3.03),
            .thigh: Model(a: 22.9405, b: 0.0234, c: 0.1989, d: 0.6665, sd: 2.25),
            .shoulderWidth: Model(a: 5.0259, b: 0.1791, c: -0.0317, d: 0.2815, sd: 1.44),
            .armLength: Model(a: -2.6693, b: 0.3542, c: 0.0097, d: -0.0016, sd: 1.76),
            .torsoLength: Model(a: 2.3206, b: 0.2094, c: 0.0078, d: 0.2282, sd: 1.88),
            .inseam: Model(a: -16.9319, b: 0.5972, c: -0.0154, d: -0.0734, sd: 2.34),
            .outseam: Model(a: -16.529, b: 0.7226, c: -0.0322, d: -0.0713, sd: 2.07),
        ],
        .female: [
            .chest: Model(a: 8.2582, b: 0.2266, c: 0.0607, d: 1.7814, sd: 4.23),
            .waist: Model(a: 36.9597, b: -0.0337, c: 0.3304, d: 1.3134, sd: 5.90),
            .hip: Model(a: -19.8668, b: 0.4558, c: -0.0464, d: 1.9780, sd: 3.83),
            .thigh: Model(a: 3.5895, b: 0.1413, c: 0.112, d: 1.0756, sd: 2.26),
            .shoulderWidth: Model(a: -4.5441, b: 0.2369, c: -0.0942, d: 0.3482, sd: 1.47),
            .armLength: Model(a: -6.2039, b: 0.3645, c: 0.01, d: 0.0561, sd: 1.73),
            .torsoLength: Model(a: 14.5451, b: 0.1369, c: 0.0744, d: -0.0127, sd: 1.82),
            .inseam: Model(a: -9.7619, b: 0.554, c: 0.0466, d: -0.2113, sd: 2.34),
            .outseam: Model(a: -21.3907, b: 0.7592, c: -0.0553, d: -0.019, sd: 2.00),
        ],
        // Sex not given: pooled fit, wider residuals.
        nil: [
            .chest: Model(a: -27.3589, b: 0.4423, c: -0.0413, d: 2.1148, sd: 3.72),
            .waist: Model(a: 68.1282, b: -0.2327, c: 0.5285, d: 0.8297, sd: 5.47),
            .hip: Model(a: 15.3713, b: 0.2266, c: -0.1440, d: 2.2039, sd: 4.61),
            .thigh: Model(a: 50.5416, b: -0.1247, c: 0.2059, d: 0.6173, sd: 2.79),
            .shoulderWidth: Model(a: -19.4397, b: 0.3137, c: -0.0782, d: 0.4382, sd: 1.74),
            .armLength: Model(a: -15.9064, b: 0.4273, c: -0.0566, d: 0.2155, sd: 1.75),
            .torsoLength: Model(a: -2.2216, b: 0.2329, c: 0.0246, d: 0.1826, sd: 1.92),
            .inseam: Model(a: -9.5051, b: 0.5566, c: -0.0002, d: -0.1259, sd: 2.36),
            .outseam: Model(a: -6.8511, b: 0.6706, c: -0.0034, d: -0.1741, sd: 2.07),
        ],
    ]

    /// Waist with age: (age − 35) years added as a term, same data. The waist widens with
    /// age at the same height and weight (about 2 mm a year); knowing the age cuts the
    /// civilian waist error by a fifth (men 4.6 → 3.6 cm mean absolute error). Hips don't
    /// depend on it.
    static let waistWithAge: [BodySex?: (model: Model, perYear: Double)] = [
        .male: (Model(a: 38.0864, b: -0.0508, c: 0.3713, d: 1.2444, sd: 4.31), 0.2142),
        .female: (Model(a: 39.5669, b: -0.0371, c: 0.3809, d: 1.0945, sd: 5.48), 0.1642),
        nil: (Model(a: 65.1645, b: -0.1996, c: 0.5290, d: 0.7261, sd: 4.86), 0.1917),
    ]

    /// Valid input range of the survey data; outside it the models extrapolate.
    public static let heightRange: ClosedRange<Double> = 140...200
    public static let weightRange: ClosedRange<Double> = 36...145

    /// Estimates for every dimension except height. Empty if the inputs are implausible.
    /// The age (adults, 18–90) sharpens the waist.
    public func estimate(heightCm: Double, weightKg: Double, sex: BodySex?, ageYears: Double? = nil) -> [BodyDimension: MeasuredValue] {
        guard (120...230).contains(heightCm), (30...250).contains(weightKg),
              let models = Self.models[sex] else { return [:] }
        let bmi = weightKg / ((heightCm / 100) * (heightCm / 100))
        // Outside the survey range the linear fit is less trustworthy.
        let extrapolating = !Self.heightRange.contains(heightCm) || !Self.weightRange.contains(weightKg)
        let extrapolation = extrapolating ? 1.5 : 1
        var values = Dictionary(uniqueKeysWithValues: models.map { dim, m in
            let factor = (Self.civilianFitted.contains(dim) ? 1 : populationShiftFactor) * extrapolation
            return (dim, MeasuredValue(cm: m.a + m.b * heightCm + m.c * weightKg + m.d * bmi,
                                       uncertaintyCm: m.sd * factor, source: .estimated))
        })
        if let age = ageYears, (18...90).contains(age), let (m, perYear) = Self.waistWithAge[sex] {
            values[.waist] = MeasuredValue(cm: m.a + m.b * heightCm + m.c * weightKg + m.d * bmi + perYear * (age - 35),
                                           uncertaintyCm: m.sd * extrapolation, source: .estimated)
        }
        return values
    }
}

/// Combines photo measurements with height/weight estimates.
public enum MeasurementFusion {
    /// For each dimension:
    /// - only one source available → use it;
    /// - both agree within `rejectSigma` combined standard deviations → inverse-variance
    ///   weighted mean, still marked as a scan;
    /// - they disagree → the photo value is treated as a failed detection and the
    ///   estimate is used (its `.estimated` source tells the UI to ask for a tape check).
    public static func fuse(scan: BodyProfile, prior: [BodyDimension: MeasuredValue],
                            rejectSigma: Double = 3) -> (profile: BodyProfile, rejected: [BodyDimension]) {
        var out = scan
        var rejected: [BodyDimension] = []
        for (dim, p) in prior {
            guard let s = scan[dim], s.source == .scan else {
                if scan[dim] == nil { out[dim] = p }
                continue
            }
            let vs = max(s.uncertaintyCm, 0.1) * max(s.uncertaintyCm, 0.1)
            let vp = max(p.uncertaintyCm, 0.1) * max(p.uncertaintyCm, 0.1)
            if abs(s.cm - p.cm) > rejectSigma * (vs + vp).squareRoot() {
                out[dim] = p
                rejected.append(dim)
            } else {
                let cm = (s.cm / vs + p.cm / vp) / (1 / vs + 1 / vp)
                out[dim] = MeasuredValue(cm: cm, uncertaintyCm: (1 / (1 / vs + 1 / vp)).squareRoot(), source: .scan)
            }
        }
        return (out, rejected.sorted { $0.rawValue < $1.rawValue })
    }
}
