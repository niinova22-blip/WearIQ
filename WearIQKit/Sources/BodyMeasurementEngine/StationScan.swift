import Foundation
import WearIQCore

/// Girths from a guided turn in eight stops, 45° apart: front, diagonal, side, diagonal
/// back, back, and round to the front again.
///
/// The user is told where to stand at each stop and holds still for a moment, so no
/// angle has to be estimated from the camera. Averaging the silhouette width over eight
/// evenly spaced directions and multiplying by π is Cauchy's perimeter formula (see
/// `RotationScanAnalyzer`) sampled at 45°; for torso-like cross-sections that is within
/// about 1% of the full average, and a stop or two turned 10–15° off barely matters.
public struct StationScan: Sendable {
    public static let stationCount = 8
    /// Stops a level needs before its girth is reported.
    public var minimumStations = 6
    public var levels: [BodyLevel] = [.chest, .waist, .hip]
    /// Eight directions slightly underestimate the mean width of boxy cross-sections.
    /// Measured on all 6,068 ANSUR II bodies (see AnsurValidationTests): chest −0.99%,
    /// waist −0.25%, hips −0.46%; these factors remove that bias.
    public var calibration: [BodyLevel: Double] = [.chest: 1.0100, .waist: 1.0025, .hip: 1.0046]

    private var widths = [[BodyLevel: Double]](repeating: [:], count: StationScan.stationCount)
    public private(set) var captured: Set<Int> = []

    public init() {}

    public mutating func record(_ levelWidths: [BodyLevel: Double], at station: Int) {
        guard (0..<Self.stationCount).contains(station) else { return }
        widths[station] = levelWidths
        captured.insert(station)
    }

    public func count(_ level: BodyLevel) -> Int { widths.filter { $0[level] != nil }.count }
    public func isMeasured(_ level: BodyLevel) -> Bool { count(level) >= minimumStations }

    /// Whether a still pose looks different enough from the last stop to be the next one.
    /// Neighbouring stops differ by 10–20% in width at the waist or hips.
    public func differs(_ candidate: [BodyLevel: Double], from station: Int, threshold: Double = 0.05) -> Bool {
        guard (0..<Self.stationCount).contains(station) else { return true }
        let previous = widths[station]
        let changes = candidate.compactMap { level, w -> Double? in
            guard let p = previous[level], p > 0 else { return nil }
            return abs(w - p) / p
        }
        guard let largest = changes.max() else { return true }
        return largest > threshold
    }

    public func girths() -> [BodyLevel: MeasuredValue] {
        var result: [BodyLevel: MeasuredValue] = [:]
        for level in levels where isMeasured(level) {
            var values = (0..<Self.stationCount).map { usableWidth(level, at: $0) }
            let n = Self.stationCount
            // A silhouette is the same width seen from opposite sides, so a missed stop
            // takes the width of the one across from it.
            for i in values.indices where values[i] == nil {
                values[i] = values[(i + n / 2) % n]
            }
            // Still missing (both opposite stops): for an elliptical cross-section
            // w(θ)² = w(θ+45°)² + w(θ−45°)² − w(θ+90°)².
            for i in values.indices where values[i] == nil {
                if let next = values[(i + 1) % n], let previous = values[(i + n - 1) % n],
                   let perpendicular = values[(i + 2) % n] {
                    let square = next * next + previous * previous - perpendicular * perpendicular
                    values[i] = square > 0 ? square.squareRoot() : nil
                }
            }
            for i in values.indices where values[i] == nil {
                values[i] = values[(i + n / 2) % n]
            }
            let filled = values.compactMap { $0 }
            guard filled.count == n, let lo = filled.min(), let hi = filled.max(),
                  lo < 0.92 * hi else { continue }  // equal widths all round: the user didn't turn
            let girth = Double.pi * filled.reduce(0, +) / Double(filled.count) * (calibration[level] ?? 1)
            result[level] = MeasuredValue(cm: girth, uncertaintyCm: 0.03 * girth, source: .scan)
        }
        return result
    }

    /// Stops to take again: a silhouette seen from opposite sides has the same width, so
    /// opposite stops that disagree by more than `tolerance` at the waist or hips mean
    /// one of them was off (turned too far, a step closer, an arm in the way). Of the
    /// pair, the one further from what its neighbours predict for an elliptical section
    /// (w(θ)² = w(θ+45°)² + w(θ−45°)² − w(θ+90°)²) is retaken. Missing stops are retaken
    /// too.
    public func stopsToRetake(tolerance: Double = 0.08) -> [Int] {
        let n = Self.stationCount
        var retake = Set((0..<n).filter { !captured.contains($0) })
        for i in 0..<(n / 2) {
            let j = i + n / 2
            var worst = 0.0
            for level in [BodyLevel.waist, .hip] {
                guard let a = widths[i][level], let b = widths[j][level], a > 0, b > 0 else { continue }
                worst = max(worst, abs(a - b) / ((a + b) / 2))
            }
            guard worst > tolerance else { continue }
            retake.insert(predictionError(i) >= predictionError(j) ? i : j)
        }
        return retake.sorted()
    }

    /// Relative gap between a stop's waist/hip width and what its neighbours predict.
    private func predictionError(_ i: Int) -> Double {
        let n = Self.stationCount
        var worst = 0.0
        for level in [BodyLevel.waist, .hip] {
            guard let w = widths[i][level], let next = widths[(i + 1) % n][level],
                  let previous = widths[(i + n - 1) % n][level], let across = widths[(i + 2) % n][level] else { continue }
            let square = next * next + previous * previous - across * across
            guard square > 0 else { continue }
            worst = max(worst, abs(w - square.squareRoot()) / w)
        }
        return worst
    }

    /// Width at a stop, without readings widened by the arms.
    private func usableWidth(_ level: BodyLevel, at station: Int) -> Double? {
        guard let width = widths[station][level] else { return nil }
        if level == .chest, Self.armsAgainstChest(widths[station], at: station) { return nil }
        return width
    }

    /// Seen from the front, back or diagonally, arms hanging against the chest make it
    /// far wider than the waist below it, which no torso is. Side-on, the arms stay
    /// within the outline.
    public static func armsAgainstChest(_ levelWidths: [BodyLevel: Double], at station: Int) -> Bool {
        guard let chest = levelWidths[.chest], let waist = levelWidths[.waist], waist > 0 else { return false }
        switch station % 4 {
        case 0: return chest > 1.35 * waist
        case 2: return false
        default: return chest > 1.3 * waist
        }
    }
}

/// Whether the user stands where a stop wants them, judged from the outline with the
/// arms held straight out to the sides.
public enum StopFit: Equatable, Sendable {
    case ok
    /// Not far enough round yet (the user always turns clockwise).
    case turnFurther
    /// Turned past the stop.
    case turnBack
    /// Arms not held out, so the outline can't show the turn.
    case openArms
    /// Head or feet outside the picture: the height, which sets the scale, can't be seen.
    case stepBack
    /// Too small in the picture to measure well.
    case comeCloser
    /// Too far to one side.
    case moveToCentre
}

public enum StopGuide {
    /// Arms straight out span about the body height; less than this at the front stop
    /// means they aren't fully open.
    public static let openArmSpan = 0.75

    /// - Parameters:
    ///   - spanRatio: arm span relative to the front stop's.
    ///   - shoulderRatio: shoulder separation relative to the front stop's, when the
    ///     shoulders are detected. Lets dropped arms be told apart from a side view.
    /// Below this fraction of the picture's height the outline is too coarse to measure.
    public static let minimumBodySpan = 0.42

    /// Whether the whole body, head to feet, is inside the picture.
    public static func fullyVisible(_ reading: FrameReading) -> Bool {
        reading.top > 0.01 && reading.floor < 0.99
    }

    /// Whether an arm has come down from shoulder height, from the pose: held out, the
    /// wrist and elbow sit level with the shoulder; hanging, the elbow is about a tenth
    /// of the body's height below it and the wrist a fifth or more. Works from any side,
    /// since the drop is vertical; an arm whose joints aren't seen doesn't count.
    public static func armsDown(_ reading: FrameReading) -> Bool {
        let span = reading.floor - reading.top
        guard span > 0 else { return false }
        let j = reading.joints
        for (shoulder, elbow, wrist) in [(BodyJoint.leftShoulder, BodyJoint.leftElbow, BodyJoint.leftWrist),
                                         (.rightShoulder, .rightElbow, .rightWrist)] {
            guard let s = j[shoulder] ?? j[.neck] else { continue }
            if let w = j[wrist], (w.y - s.y) / span > 0.2 { return true }
            if j[wrist] == nil, let e = j[elbow], (e.y - s.y) / span > 0.1 { return true }
        }
        return false
    }

    public static func fit(station: Int, spanRatio r: Double, shoulderRatio: Double?) -> StopFit {
        let shouldersWide = (shoulderRatio ?? 0) > 0.75
        switch station % 4 {
        case 0:  // facing or backing onto the camera: full span
            if r >= 0.85 { return .ok }
            return shouldersWide && r < 0.6 ? .openArms : .turnFurther
        case 2:  // side-on: the arms point at and away from the camera
            if r <= 0.5 { return shouldersWide ? .openArms : .ok }
            return .turnFurther
        default:  // diagonal: about cos 45° of the span
            if r > 0.85 { return .turnFurther }
            if r >= 0.45 { return .ok }
            return shouldersWide ? .openArms : .turnBack
        }
    }
}

/// Notices when the user stands still, and gives the widths measured during that moment.
public struct StillnessDetector: Sendable {
    /// How long the pose has to hold, in seconds.
    public var window = 0.55
    /// Allowed relative change in width while still.
    public var tolerance = 0.035
    /// Allowed sideways drift, as a fraction of the image width.
    public var drift = 0.03

    private var samples: [(time: Double, reading: FrameReading)] = []

    public init() {}

    public mutating func add(_ reading: FrameReading, time: Double) {
        samples.append((time, reading))
        samples.removeAll { time - $0.time > window * 1.5 }
    }

    public mutating func reset() { samples.removeAll() }

    /// Median width per level over the last `window` seconds, or `nil` if the user moved.
    public func stillWidths(at time: Double) -> [BodyLevel: Double]? {
        let recent = samples.filter { time - $0.time <= window }
        guard recent.count >= 3, let first = recent.first, time - first.time >= window * 0.7 else { return nil }
        let centers = recent.map(\.reading.centerX)
        guard let cMin = centers.min(), let cMax = centers.max(), cMax - cMin <= drift else { return nil }

        var result: [BodyLevel: Double] = [:]
        for level in BodyLevel.allCases {
            let values = recent.compactMap { $0.reading.levels[level]?.widthCm }.sorted()
            guard values.count * 2 >= recent.count else { continue }
            let median = values[values.count / 2]
            // The steadiest torso levels decide whether the user is still.
            if level == .waist || level == .hip, let lo = values.first, let hi = values.last,
               (hi - lo) / median > tolerance { return nil }
            result[level] = median
        }
        return result[.waist] != nil || result[.hip] != nil ? result : nil
    }
}
