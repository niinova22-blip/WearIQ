import Foundation
import WearIQCore

/// One continuous turn, filmed: the user holds the arms out and turns slowly once
/// round in place, and the eight directions are found in the recording instead of the
/// user stopping at each.
///
/// The arm span over the front view's is about |cos θ| (never below the body's depth),
/// so it runs high (front), low (side), high (back), low (other side), high (front
/// again). Those four turning points mark the quarters of the turn; each quarter's
/// middle is a diagonal. Finding them in the signal, rather than assuming a steady
/// speed, keeps the eight directions right when the user turns faster through some of
/// the turn than the rest. Each direction's widths are the median of the frames around
/// it, so one bad mask doesn't decide it.
public struct TurnRecording: Sendable {
    public struct Sample: Sendable {
        public var time: Double
        /// Arm span over the front view's.
        public var spanRatio: Double
        public var widths: [BodyLevel: Double]

        public init(time: Double, spanRatio: Double, widths: [BodyLevel: Double]) {
            self.time = time
            self.spanRatio = spanRatio
            self.widths = widths
        }
    }

    /// Above this the user faces (or backs onto) the camera; below `low`, side-on.
    public var high = 0.82
    public var low = 0.5
    /// A turn quicker than this is too fast to measure well (the user is asked to count
    /// to ten while turning: about ten seconds, 25 frames a quarter at 10 fps).
    public var minimumDuration = 6.0

    public private(set) var samples: [Sample] = []

    public init() {}

    public mutating func add(_ sample: Sample) {
        samples.append(sample)
    }

    public mutating func reset() { samples.removeAll() }

    /// The span, smoothed over five frames (a median: a dropped arm for a frame or a
    /// segmentation slip doesn't make a turning point).
    private var smoothed: [Double] {
        let r = samples.map(\.spanRatio)
        return r.indices.map { i in
            let window = r[max(0, i - 2)...min(r.count - 1, i + 2)].sorted()
            return window[window.count / 2]
        }
    }

    /// Times of the turning points found so far: the first side, the back, the other
    /// side and the front again. Each is the middle of its stretch beyond the threshold
    /// (below `low` for a side, above `high` for the back), which a noisy flat top or
    /// bottom doesn't move the way its single extreme would. The front at the end is
    /// still going when the turn completes; it counts once the span has stayed high for
    /// half a second.
    public var turningPoints: [Double] {
        let r = smoothed
        guard !r.isEmpty else { return [] }
        var stretches: [(start: Double, end: Double, isLow: Bool)] = []
        var current: (start: Double, end: Double, isLow: Bool)?
        for i in r.indices {
            let t = samples[i].time
            let state: Bool? = r[i] < low ? true : r[i] > high ? false : nil
            if let state {
                if let c = current, c.isLow == state {
                    current!.end = t
                } else {
                    if let c = current { stretches.append(c) }
                    current = (t, t, state)
                }
            }
        }
        if let c = current { stretches.append(c) }
        // From the front: drop the opening high stretch, keep alternating low/high.
        var points: [Double] = []
        var expectLow = true
        var lastHighHalf: Double?
        var finalHigh: (start: Double, end: Double)?
        for (k, st) in stretches.enumerated() {
            if k == 0, !st.isLow { continue }
            guard st.isLow == expectLow else { continue }
            if points.count == 3 {
                finalHigh = (st.start, st.end)
                break
            }
            points.append((st.start + st.end) / 2)
            if !st.isLow { lastHighHalf = (st.end - st.start) / 2 }
            expectLow.toggle()
        }
        // Facing the camera again for half a second: round. (The user may turn faster or
        // slower here than through the back, so the back's stretch can't time it.)
        if let f = finalHigh, f.end - f.start >= 0.5 {
            points.append(f.start + min(lastHighHalf ?? 0.5, f.end - f.start))
        }
        return points
    }

    /// When, between two times, the span crosses `level` (nearest the middle); nil if
    /// it doesn't.
    private func crossing(_ level: Double, from a: Double, to b: Double) -> Double? {
        let r = smoothed
        let middle = (a + b) / 2
        var best: Double?
        for i in 1..<max(1, samples.count) {
            let t0 = samples[i - 1].time, t1 = samples[i].time
            guard t0 >= a, t1 <= b, (r[i - 1] - level) * (r[i] - level) <= 0, r[i] != r[i - 1] else { continue }
            let t = t0 + (t1 - t0) * (level - r[i - 1]) / (r[i] - r[i - 1])
            if best == nil || abs(t - middle) < abs(best! - middle) { best = t }
        }
        return best
    }

    /// How far round the user is, 0–1, in quarters (for the progress ring).
    public var progress: Double {
        let points = turningPoints
        guard let start = samples.first?.time else { return 0 }
        if points.count >= 4 { return 1 }
        // Within the current quarter, by time against the last quarter's length.
        let previous = points.last ?? start
        let quarter = points.count >= 1 ? (previous - start) / Double(points.count) : 3
        let now = samples.last?.time ?? start
        let within = min(0.95, (now - previous) / max(1, quarter))
        return (Double(points.count) + within) / 4
    }

    public var isComplete: Bool {
        guard let start = samples.first?.time, turningPoints.count == 4 else { return false }
        return (turningPoints[3] - start) >= minimumDuration
    }

    /// Too fast: all the way round in under `minimumDuration`.
    public var tooFast: Bool {
        guard let start = samples.first?.time, turningPoints.count == 4 else { return false }
        return turningPoints[3] - start < minimumDuration
    }

    /// The widths at the eight directions, 45° apart from the front, clockwise as the
    /// user turned; nil where no frame was close enough.
    public func stations() -> [[BodyLevel: Double]?] {
        let points = turningPoints
        guard points.count == 4, let start = samples.first?.time else { return Array(repeating: nil, count: 8) }
        let marks = [start] + points  // 0°, 90°, 180°, 270°, 360°
        var out: [[BodyLevel: Double]?] = []
        for k in 0..<8 {
            let q = k / 2
            let a = marks[q], b = marks[q + 1]
            // A diagonal is where the span passes cos 45° on its way between the two;
            // halfway in time only if the user turned evenly.
            let target = k % 2 == 0 ? a : crossing(0.707, from: a, to: b) ?? (a + b) / 2
            // Frames within a fifth of the quarter either side (about ±18°).
            let reach = max(0.15, (b - a) * 0.2)
            let near = samples.filter { abs($0.time - target) <= reach }
            var widths: [BodyLevel: Double] = [:]
            for level in BodyLevel.allCases {
                let values = near.compactMap { $0.widths[level] }.sorted()
                if !values.isEmpty { widths[level] = values[values.count / 2] }
            }
            out.append(widths.isEmpty ? nil : widths)
        }
        return out
    }

    // MARK: Every frame

    /// The turn's angle at each sample, degrees from the front, clockwise: piecewise
    /// linear through the points the span marks (the diagonals where it crosses cos 45°,
    /// the sides and the back at the middle of their stretches). Nil outside the first
    /// and last diagonal, where the span can't tell how far round the user is (still
    /// standing at the start, slowing down at the end).
    public func angles() -> [Double?] {
        let points = turningPoints
        guard points.count == 4, let start = samples.first?.time else { return samples.map { _ in nil } }
        let marks = [start] + points
        var knots: [(time: Double, degrees: Double)] = []
        for q in 0..<4 {
            if let d = crossing(0.707, from: marks[q], to: marks[q + 1]) { knots.append((d, Double(q) * 90 + 45)) }
            if q < 3 { knots.append((marks[q + 1], Double(q + 1) * 90)) }
        }
        knots.sort { $0.time < $1.time }
        guard knots.count >= 4, knots.first!.degrees == 45, knots.last!.degrees == 315 else { return samples.map { _ in nil } }
        return samples.map { sample in
            guard sample.time >= knots.first!.time, sample.time <= knots.last!.time else { return nil }
            let k = knots.lastIndex { $0.time <= sample.time } ?? 0
            guard k + 1 < knots.count else { return knots[k].degrees }
            let a = knots[k], b = knots[k + 1]
            return a.degrees + (b.degrees - a.degrees) * (sample.time - a.time) / max(1e-6, b.time - a.time)
        }
    }

    /// Girths from every frame of the turn rather than eight: per level, the widths are
    /// fitted against the angle with a smooth curve of the shape a silhouette's width
    /// takes (the same seen from opposite sides, so even harmonics only: 2θ, 4θ, 6θ),
    /// by iteratively reweighted least squares that sets aside frames far off the curve
    /// (a mask that took in an arm, a frame blurred mid-step). By Cauchy's formula the
    /// perimeter is π times the mean width, which is the curve's constant term, so
    /// uneven turning speed and uneven coverage don't bias it, and the noise of single
    /// frames averages out over about seventy of them instead of eight medians.
    /// `calibration` removes the small bias measured on ANSUR II (AnsurValidationTests).
    public func girths(calibration: [BodyLevel: Double] = TurnRecording.calibration) -> [BodyLevel: MeasuredValue] {
        let theta = angles()
        var out: [BodyLevel: MeasuredValue] = [:]
        for level in [BodyLevel.chest, .waist, .hip] {
            var xs: [Double] = [], ys: [Double] = []
            for (i, s) in samples.enumerated() {
                guard let t = theta[i], let w = s.widths[level], w > 0 else { continue }
                xs.append(t * .pi / 180)
                ys.append(w)
            }
            // At least most of the turn, spread over the half circle of directions.
            guard xs.count >= 24 else { continue }
            let folded = Set(xs.map { Int(($0.truncatingRemainder(dividingBy: .pi)) / (.pi / 8)) })
            guard folded.count >= 7 else { continue }
            guard let fit = Self.robustFit(xs, ys, harmonics: 3) else { continue }
            let mean = fit.mean
            guard mean > 0, let lo = ys.min(), let hi = ys.max(), lo < 0.92 * hi else { continue }
            let girth = Double.pi * mean * (calibration[level] ?? 1)
            // Uncertainty: the scatter about the curve over the frames used, plus a
            // floor for what the mask itself gets wrong the same way in every frame.
            let se = fit.residualSD / Double(max(1, fit.used)).squareRoot()
            out[level] = MeasuredValue(cm: girth, uncertaintyCm: (pow(.pi * se, 2) + pow(0.02 * girth, 2)).squareRoot(), source: .scan)
        }
        return out
    }

    /// Measured on ANSUR II bodies with the simulated filmed turn (FilmedTurnValidationTests):
    /// chest +0.08%, waist +0.02%, hips +0.04% before; these factors take it out.
    public static let calibration: [BodyLevel: Double] = [.chest: 0.9992, .waist: 0.9998, .hip: 0.9996]

    struct Fit { var mean: Double; var residualSD: Double; var used: Int }

    /// w(θ) = c₀ + Σ aₖ cos 2kθ + bₖ sin 2kθ by Huber-weighted least squares.
    static func robustFit(_ x: [Double], _ y: [Double], harmonics: Int) -> Fit? {
        let p = 1 + 2 * harmonics
        guard x.count > p + 4 else { return nil }
        func row(_ t: Double) -> [Double] {
            var r = [1.0]
            for k in 1...harmonics { r.append(cos(2 * Double(k) * t)); r.append(sin(2 * Double(k) * t)) }
            return r
        }
        let rows = x.map(row)
        var weights = [Double](repeating: 1, count: x.count)
        var coef = [Double](repeating: 0, count: p)
        var sd = 0.0
        // Huber weights within one robust standard deviation, frames beyond three set aside.
        for _ in 0..<8 {
            var a = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
            var b = [Double](repeating: 0, count: p)
            for (i, r) in rows.enumerated() where weights[i] > 0 {
                for j in 0..<p {
                    b[j] += weights[i] * r[j] * y[i]
                    for k in 0..<p { a[j][k] += weights[i] * r[j] * r[k] }
                }
            }
            guard let solved = solve(a, b) else { return nil }
            coef = solved
            let residuals = rows.indices.map { i in y[i] - zip(rows[i], coef).reduce(0) { $0 + $1.0 * $1.1 } }
            let mad = residuals.map(abs).sorted()[residuals.count / 2]
            sd = max(1e-6, 1.4826 * mad)
            let c = 1.0 * sd
            weights = residuals.map { r in abs(r) <= c ? 1 : abs(r) > 3 * sd ? 0 : c / abs(r) }
        }
        return Fit(mean: coef[0], residualSD: sd, used: weights.filter { $0 > 0 }.count)
    }

    /// Gaussian elimination with partial pivoting.
    static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        let n = v.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot); v.swapAt(col, pivot)
            for r in (col + 1)..<n {
                let f = m[r][col] / m[col][col]
                for c in col..<n { m[r][c] -= f * m[col][c] }
                v[r] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[r]
            for c in (r + 1)..<n { sum -= m[r][c] * x[c] }
            x[r] = sum / m[r][r]
        }
        return x
    }
}
