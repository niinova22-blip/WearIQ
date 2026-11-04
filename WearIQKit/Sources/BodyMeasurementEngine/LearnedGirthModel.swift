import Foundation
import WearIQCore

/// Engine C: chest, waist and hip girths from the filmed turn by a small model trained
/// on synthetic turns (scripts/scan_training/, docs/SCAN_TRAINING.md), run on the phone,
/// offline, in well under a millisecond.
///
/// Why: Cauchy's formula (girth = π × mean width) is exact for a level slice seen from
/// far away, but a phone 2–3 m away sees rows of the picture, not level slices, at
/// heights placed from the skeleton, scaled by a mask that includes hair. On SOMA-X
/// bodies of ANSUR II people filmed that way the current engine reads chests 3.4 cm
/// small on average (MAE 4.8 cm); this model, given the same frames, 1.2 cm.
///
/// What it sees, per level (`features`): the girth by Cauchy at the level row; the mean
/// widths of the rows 1–3% of stature above and below, relative to it (the body's
/// shape around the level: a bust, a belly); how much wider the body is one way than
/// the other (even harmonics of width against angle) at the level and either side;
/// where the person stands in the picture (the mask's top and floor rows: distance and
/// camera height); height, weight and sex; the other two levels' widths relative to it.
///
/// Since 2026-11-05 it corrects the production scan for the camera's perspective
/// (`correct`), after simulated turns of an independent tape-measured population showed
/// the plain widths reading men's chests 4.6 cm small and it close to exact; the
/// owner's own taped scan in validation mode is the check on a real phone.
public enum LearnedGirthModel {
    /// Rows measured around each level, as fractions of stature above (+) or below (−)
    /// it. Index 3 is the level row.
    public static let offsets: [Double] = [-0.03, -0.02, -0.01, 0, 0.01, 0.02, 0.03]
    public static let levels: [BodyLevel] = [.chest, .waist, .hip]

    public struct Weights: Sendable {
        public enum Kind: Sendable { case linear, network }
        var kind: Kind
        var mean: [Double]
        var scale: [Double]
        var intercept: Double
        /// Linear: one per feature. Network: one per hidden unit.
        var weights: [Double]
        /// Network: hidden × features, row-major, and the hidden biases.
        var hidden: [Double] = []
        var hiddenBias: [Double] = []
        /// Residual spread on held-out validation turns (cm), widened for the gap between
        /// synthetic and real recordings.
        var sdCm: Double = 2.5
    }

    /// The constant and even harmonics of width against angle: the robust mean (π × it
    /// is Cauchy's girth) and the 2θ and 4θ terms by least squares. Nil with too few
    /// frames over too little of the turn.
    public static func harmonics(_ widths: [Double?], angles: [Double?]) -> (mean: Double, cos2: Double, sin2: Double, cos4: Double)? {
        var x: [Double] = [], y: [Double] = []
        for (w, a) in zip(widths, angles) {
            guard let w, let a else { continue }
            x.append(a * .pi / 180); y.append(w)
        }
        guard x.count >= 24, let robust = TurnRecording.robustFit(x, y, harmonics: 3) else { return nil }
        let rows = x.map { [1, cos(2 * $0), sin(2 * $0), cos(4 * $0), sin(4 * $0)] }
        var a = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 5), b = [Double](repeating: 0, count: 5)
        for (r, v) in zip(rows, y) { for i in 0..<5 { b[i] += r[i] * v; for j in 0..<5 { a[i][j] += r[i] * r[j] } } }
        guard let c = TurnRecording.solve(a, b) else { return nil }
        return (robust.mean, c[1], c[2], c[3])
    }

    /// The feature vector for each level the turn covers, in the order the model was
    /// trained with (scripts/scan_training/train.py reads these as written).
    public static func features(_ rec: TurnRecording, heightCm: Double, weightKg: Double, sex: BodySex?) -> [BodyLevel: [Double]] {
        let angles = rec.angles()
        var fits: [BodyLevel: [(mean: Double, cos2: Double, sin2: Double, cos4: Double)?]] = [:]
        for level in levels {
            fits[level] = offsets.indices.map { k in
                harmonics(rec.samples.map { $0.profile[level]?[k] ?? nil }, angles: angles)
            }
        }
        let tops = rec.samples.compactMap(\.top).sorted(), floors = rec.samples.compactMap(\.floor).sorted()
        guard !tops.isEmpty, !floors.isEmpty, heightCm > 0, weightKg > 0 else { return [:] }
        let top = tops[tops.count / 2], floor = floors[floors.count / 2]
        let bmi = weightKg / pow(heightCm / 100, 2)
        var out: [BodyLevel: [Double]] = [:]
        for level in levels {
            guard let centre = fits[level]?[3], centre.mean > 0 else { continue }
            let m = centre.mean
            var f = [log(Double.pi * m)]
            for k in offsets.indices where k != 3 {
                f.append((fits[level]?[k]).flatMap { $0 }.map { $0.mean > 0 ? $0.mean / m - 1 : 0 } ?? 0)
            }
            for k in [2, 3, 4] {
                let h = (fits[level]?[k]).flatMap { $0 }
                f += [h.map { $0.cos2 / m } ?? 0, h.map { $0.sin2 / m } ?? 0, h.map { $0.cos4 / m } ?? 0]
            }
            f += [top, floor, floor - top, (floor + top) / 2, (floor - top) * (floor - top),
                  heightCm / 100, log(weightKg), bmi / 25, sex == .female ? 1 : 0]
            for other in levels where other != level {
                f.append((fits[other]?[3]).flatMap { $0 }.map { $0.mean > 0 ? $0.mean / m : 0 } ?? 0)
            }
            out[level] = f
        }
        return out
    }

    /// Girths from a finished turn. Needs the rows around each level and the mask's top
    /// and floor in the samples (`TurnRecording.Sample.profile`, `top`, `floor`).
    public static func girths(_ rec: TurnRecording, heightCm: Double, weightKg: Double, sex: BodySex?) -> [BodyLevel: MeasuredValue] {
        girths(rec, heightCm: heightCm, weightKg: weightKg, sex: sex, weights: trained)
    }

    /// The scan's girths with engine C's reading of the turn (in production since
    /// 2026-11-05). The plain widths of a filmed turn read men's chests about 4.6 cm and
    /// hips about 3 cm small, mostly from the camera's perspective (simulated on the
    /// 507 tape-measured adults of Heinz et al. 2003, a population C never saw; C's mean
    /// error there is 1.2–2.0 cm against 2.6–5.5 cm). Per level, C's value over the plain
    /// fit becomes a factor (`StationScan.perspective`) for the stops and stills as well,
    /// and the every-frame value is C's own. A factor beyond ±15% means C is outside
    /// what it learned: that level keeps the plain reading.
    public static func correct(_ scan: inout StationScan, turn: TurnRecording, plain: [BodyLevel: MeasuredValue],
                               heightCm: Double, weightKg: Double, sex: BodySex?) {
        let learned = girths(turn, heightCm: heightCm, weightKg: weightKg, sex: sex)
        scan.everyFrame = plain
        for level in [BodyLevel.chest, .waist, .hip] {
            guard let a = plain[level], let c = learned[level], a.cm > 0 else { continue }
            let factor = c.cm / a.cm
            guard (0.85...1.15).contains(factor) else { continue }
            scan.perspective[level] = factor
            scan.everyFrame[level] = MeasuredValue(cm: c.cm, uncertaintyCm: max(c.uncertaintyCm, a.uncertaintyCm * factor),
                                                   source: .scan)
        }
    }

    /// Whether trained weights are bundled for every level.
    public static var isTrained: Bool { levels.allSatisfy { trained[$0] != nil } }

    static func girths(_ rec: TurnRecording, heightCm: Double, weightKg: Double, sex: BodySex?,
                       weights: [BodyLevel: Weights]) -> [BodyLevel: MeasuredValue] {
        var out: [BodyLevel: MeasuredValue] = [:]
        for (level, f) in features(rec, heightCm: heightCm, weightKg: weightKg, sex: sex) {
            guard let w = weights[level], let cm = predict(f, w), cm.isFinite, cm > 30, cm < 260 else { continue }
            out[level] = MeasuredValue(cm: cm, uncertaintyCm: w.sdCm, source: .scan)
        }
        return out
    }

    static func predict(_ f: [Double], _ w: Weights) -> Double? {
        guard f.count == w.mean.count, f.allSatisfy(\.isFinite) else { return nil }
        let z = f.indices.map { (f[$0] - w.mean[$0]) / w.scale[$0] }
        switch w.kind {
        case .linear:
            return exp(w.intercept + zip(z, w.weights).reduce(0) { $0 + $1.0 * $1.1 })
        case .network:
            let n = z.count
            var out = w.intercept
            for (j, v) in w.weights.enumerated() {
                var s = w.hiddenBias[j]
                for i in 0..<n { s += w.hidden[j * n + i] * z[i] }
                out += v * tanh(s)
            }
            return exp(out)
        }
    }
}
