import Foundation

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
}
