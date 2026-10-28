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
/// SD is inflated by `populationShiftFactor`. These are statistical estimates for a typical
/// body of that height and weight, never a measurement of this person.
public struct AnthropometricPrior: Sendable {
    struct Model {
        let a, b, c, d: Double
        /// Residual standard deviation in cm.
        let sd: Double
    }

    public var populationShiftFactor = 1.3

    public init() {}

    static let models: [BodySex?: [BodyDimension: Model]] = [
        .male: [
            .chest: Model(a: 17.7891, b: 0.1955, c: 0.1214, d: 1.5662, sd: 3.19),
            .waist: Model(a: 10.0937, b: 0.0877, c: 0.2559, d: 1.6856, sd: 4.37),
            .hip: Model(a: 10.2651, b: 0.2597, c: 0.1219, d: 1.2875, sd: 2.60),
            .thigh: Model(a: 22.9405, b: 0.0234, c: 0.1989, d: 0.6665, sd: 2.25),
            .shoulderWidth: Model(a: 5.0259, b: 0.1791, c: -0.0317, d: 0.2815, sd: 1.44),
            .armLength: Model(a: -2.6693, b: 0.3542, c: 0.0097, d: -0.0016, sd: 1.76),
            .torsoLength: Model(a: 2.3206, b: 0.2094, c: 0.0078, d: 0.2282, sd: 1.88),
            .inseam: Model(a: -16.9319, b: 0.5972, c: -0.0154, d: -0.0734, sd: 2.34),
            .outseam: Model(a: -16.529, b: 0.7226, c: -0.0322, d: -0.0713, sd: 2.07),
        ],
        .female: [
            .chest: Model(a: 8.2582, b: 0.2266, c: 0.0607, d: 1.7814, sd: 4.23),
            .waist: Model(a: 0.2703, b: 0.1475, c: 0.1653, d: 1.9848, sd: 4.81),
            .hip: Model(a: -7.9135, b: 0.3885, c: 0.0065, d: 1.8172, sd: 2.90),
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
            .waist: Model(a: 21.3681, b: 0.0258, c: 0.269, d: 1.6397, sd: 4.54),
            .hip: Model(a: 86.2695, b: -0.154, c: 0.2683, d: 0.7696, sd: 4.06),
            .thigh: Model(a: 50.5416, b: -0.1247, c: 0.2059, d: 0.6173, sd: 2.79),
            .shoulderWidth: Model(a: -19.4397, b: 0.3137, c: -0.0782, d: 0.4382, sd: 1.74),
            .armLength: Model(a: -15.9064, b: 0.4273, c: -0.0566, d: 0.2155, sd: 1.75),
            .torsoLength: Model(a: -2.2216, b: 0.2329, c: 0.0246, d: 0.1826, sd: 1.92),
            .inseam: Model(a: -9.5051, b: 0.5566, c: -0.0002, d: -0.1259, sd: 2.36),
            .outseam: Model(a: -6.8511, b: 0.6706, c: -0.0034, d: -0.1741, sd: 2.07),
        ],
    ]

    /// Valid input range of the survey data; outside it the models extrapolate.
    public static let heightRange: ClosedRange<Double> = 140...200
    public static let weightRange: ClosedRange<Double> = 36...145

    /// Estimates for every dimension except height. Empty if the inputs are implausible.
    public func estimate(heightCm: Double, weightKg: Double, sex: BodySex?) -> [BodyDimension: MeasuredValue] {
        guard (120...230).contains(heightCm), (30...250).contains(weightKg),
              let models = Self.models[sex] else { return [:] }
        let bmi = weightKg / ((heightCm / 100) * (heightCm / 100))
        // Outside the survey range the linear fit is less trustworthy.
        let extrapolating = !Self.heightRange.contains(heightCm) || !Self.weightRange.contains(weightKg)
        let factor = populationShiftFactor * (extrapolating ? 1.5 : 1)
        return models.mapValues { m in
            MeasuredValue(cm: m.a + m.b * heightCm + m.c * weightKg + m.d * bmi,
                          uncertaintyCm: m.sd * factor, source: .estimated)
        }
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
