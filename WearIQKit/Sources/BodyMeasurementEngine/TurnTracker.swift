import Foundation

/// Live progress of the 360° turn: how far the user has turned and which body levels
/// have been seen from every direction, so guidance can fill in region by region.
///
/// Progress comes from the folded axis angle (0° facing, 90° side-on, see
/// `RotationFrame.axisAngle`). A full turn sweeps it 0→90→0→90→0, so it is counted in
/// quarter turns: a quarter ends when the angle passes well into the other half. Pose
/// models rarely reach exactly 0° or 90°, and counting threshold crossings instead of
/// summing angle changes keeps jitter and those shortfalls from skewing the total.
public struct TurnTracker: Sendable {
    public static let sectorCount = 12
    /// Samples a level needs in every angle bin before it counts as measured.
    public var samplesPerBin = 2
    public var levels: [BodyLevel] = [.chest, .waist, .hip]
    /// A quarter turn towards side-on ends above this angle, towards facing below `lowAngle`.
    public var highAngle = 65.0
    public var lowAngle = 25.0

    public private(set) var quarters = 0
    /// Time of the last real progress, to notice when the user has stopped turning.
    public private(set) var lastProgressTime: Double?
    private var rising = true
    private var partial = 0.0
    private var smoothed: Double?
    private var counts: [BodyLevel: [Int]] = [:]
    private var history: [(time: Double, rotation: Double)] = []
    private var startTime: Double?

    public init() {}

    /// Degrees turned so far, 0–360.
    public var rotation: Double { min(360, (Double(quarters) + partial) * 90) }
    public var completedSectors: Int { min(Self.sectorCount, Int(rotation / (360 / Double(Self.sectorCount)))) }

    /// Fraction of angle bins in which `level` has been measured, 0–1.
    public func coverage(_ level: BodyLevel) -> Double {
        let bins = counts[level] ?? []
        return Double(bins.filter { $0 >= samplesPerBin }.count) / Double(RotationScanAnalyzer.angleBins)
    }

    public var isComplete: Bool { quarters >= 4 && levels.allSatisfy { coverage($0) >= 1 } }

    /// Turning speed over the last two seconds, in degrees per second.
    public var speed: Double {
        guard let first = history.first, let last = history.last, last.time - first.time > 0.5 else { return 0 }
        return (last.rotation - first.rotation) / (last.time - first.time)
    }

    /// Seconds since the turn last advanced.
    public func idle(at time: Double) -> Double { time - (lastProgressTime ?? startTime ?? time) }

    /// - Parameters:
    ///   - measured: Levels whose width could be read in this frame.
    public mutating func add(axisAngle: Double?, measured: Set<BodyLevel>, time: Double) {
        if startTime == nil { startTime = time }
        guard let axisAngle else { return }
        let angle = min(90, max(0, axisAngle))
        let s = smoothed.map { 0.4 * $0 + 0.6 * angle } ?? angle
        if smoothed == nil { rising = s < 45 }
        smoothed = s

        let before = rotation
        if rising, s > highAngle {
            quarters += 1
            rising = false
            partial = 0
        } else if !rising, s < lowAngle {
            quarters += 1
            rising = true
            partial = 0
        } else {
            // Within a quarter, progress only moves forward so jitter can't undo it.
            let position = rising ? s / highAngle : (90 - s) / (90 - lowAngle)
            partial = max(partial, min(0.95, max(0, position)))
        }
        if rotation - before >= 2 { lastProgressTime = time }
        history.append((time, rotation))
        history.removeAll { time - $0.time > 2 }

        let bin = RotationScanAnalyzer.angleBin(angle)
        for level in levels where measured.contains(level) {
            var bins = counts[level] ?? [Int](repeating: 0, count: RotationScanAnalyzer.angleBins)
            bins[bin] += 1
            counts[level] = bins
        }
    }
}
