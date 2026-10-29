import Foundation
import WearIQCore

/// One frame of the 360° turn: the person mask and, when detected, the hip centre.
public struct RotationFrame: Sendable {
    public var mask: BinaryMask
    /// Body centre column (root joint), if Vision found it in this frame.
    public var centerX: Double?
    public var time: Double
    /// Angle between the body's left–right axis and the image plane, 0° facing (or
    /// backing onto) the camera, 90° side-on. Folded this way it doesn't depend on
    /// which way the user turns or on front/back confusions of the pose model.
    public var axisAngle: Double?
    /// Detected joints, normalised image coordinates (y down).
    public var joints: [BodyJoint: Point2D]

    public init(mask: BinaryMask, centerX: Double?, time: Double, axisAngle: Double? = nil,
                joints: [BodyJoint: Point2D] = [:]) {
        self.mask = mask
        self.centerX = centerX
        self.time = time
        self.axisAngle = axisAngle
        self.joints = joints
    }
}

/// Where a body level lies in one turn frame, in normalised image coordinates (y down).
public struct LevelReading: Sendable, Equatable {
    public var y: Double
    public var left: Double
    public var right: Double
    /// Silhouette width in cm, scaled by the person's height in this frame.
    public var widthCm: Double
}

/// The person's outline in one turn frame, for live guidance and overlays.
public struct FrameReading: Sendable, Equatable {
    public var top: Double
    public var floor: Double
    public var centerX: Double
    public var levels: [BodyLevel: LevelReading]
    /// Widest outline across the shoulder band, as a fraction of body height. With the
    /// arms held straight out it is about 1 seen from the front or back, about 0.7 from
    /// a diagonal and only the body's depth side-on, so it shows how far the user has
    /// turned without estimating any angle.
    public var armSpan: Double? = nil
    /// Detected joints, normalised image coordinates (y down).
    public var joints: [BodyJoint: Point2D] = [:]
    /// Upper-arm thickness over stature, read with the arms held out; nil otherwise.
    public var armThickness: Double? = nil
    /// The person's outer outline, top to bottom, for drawing it live.
    public var outline: [OutlineRow] = []
}

/// One row of the outer outline: leftmost and rightmost person pixel, normalised.
public struct OutlineRow: Sendable, Equatable {
    public var y: Double
    public var left: Double
    public var right: Double
}

public enum RotationScanError: Error, Equatable {
    /// Too few usable frames, or the frames don't show a full turn.
    case incompleteTurn
}

/// Measures girths from a slow 360° turn in front of a fixed camera.
///
/// Cauchy's surface-area formula: the perimeter of a convex shape equals π times its
/// mean width over all viewing directions. A tape measure follows the convex hull of
/// the body's cross-section, so averaging the silhouette width at a body level over a
/// full turn and multiplying by π gives the tape-measure girth directly, without any
/// assumption about the cross-section's shape.
///
/// Each frame is scaled by the person's height in that frame (the user's typed height
/// is the ruler), so stepping slightly closer or further during the turn doesn't matter.
///
/// When frames carry the body's axis angle, widths are averaged per angle bin first, so
/// turning faster through some directions than others doesn't bias the mean. A body is
/// close to mirror-symmetric, so its widths at θ, −θ and θ+180° match and 0–90° covers
/// every distinct view.
public struct RotationScanAnalyzer: Sendable {
    /// Angle bins over 0–90° used to balance the mean width.
    public static let angleBins = 6
    public var minRowPixels = 3
    /// Minimum frames for a turn.
    public var minimumFrames = 24
    /// Widths more than this factor above the neighbourhood median are arm contact or
    /// segmentation spikes, and are dropped.
    public var spikeFactor = 1.18

    public init() {}

    /// - Parameters:
    ///   - levelFractions: Height of each level below the top of the head, as a fraction
    ///     of body height (from the front photo).
    public func girths(frames: [RotationFrame], heightCm: Double,
                       levelFractions: [BodyLevel: Double]) throws -> [BodyLevel: MeasuredValue] {
        let usable = frames.compactMap { frame -> (frame: RotationFrame, top: Int, height: Int)? in
            guard let (top, floor) = verticalExtent(frame.mask), floor - top > frame.mask.height / 4 else { return nil }
            return (frame, top, floor - top)
        }
        guard usable.count >= minimumFrames else { throw RotationScanError.incompleteTurn }

        var result: [BodyLevel: MeasuredValue] = [:]
        for (level, fraction) in levelFractions where level != .thigh {
            var samples: [(width: Double, angle: Double?)] = []
            for (frame, top, height) in usable {
                guard let reading = levelReading(frame, top: top, height: height, fraction: fraction, heightCm: heightCm) else { continue }
                samples.append((reading.widthCm, frame.axisAngle))
            }
            let clean = keptIndices(samples.map(\.width)).map { samples[$0] }
            let widths = clean.map(\.width)
            // A real turn shows both the wide (front/back) and narrow (side) views.
            guard widths.count >= minimumFrames / 2, let lo = widths.min(), let hi = widths.max(), lo < 0.88 * hi else { continue }
            let mean = Self.angleBalancedMean(clean) ?? widths.reduce(0, +) / Double(widths.count)
            let sd = (widths.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(widths.count)).squareRoot()
            let girth = Double.pi * mean
            // Statistical error of the mean plus 2% for segmentation edges and uneven turning speed.
            let uncertainty = ((Double.pi * sd / Double(widths.count).squareRoot()).squared + (0.02 * girth).squared).squareRoot()
            result[level] = MeasuredValue(cm: girth, uncertaintyCm: uncertainty, source: .scan)
        }
        guard !result.isEmpty else { throw RotationScanError.incompleteTurn }
        return result
    }

    /// Outline of the person and the width at each level in a single frame, for live
    /// guidance. `nil` when no person is visible.
    public func reading(_ frame: RotationFrame, heightCm: Double, levelFractions: [BodyLevel: Double]) -> FrameReading? {
        guard let (top, floor) = verticalExtent(frame.mask), floor - top > frame.mask.height / 4 else { return nil }
        let w = Double(frame.mask.width), h = Double(frame.mask.height)
        var levels: [BodyLevel: LevelReading] = [:]
        for (level, fraction) in levelFractions where level != .thigh {
            levels[level] = levelReading(frame, top: top, height: floor - top, fraction: fraction, heightCm: heightCm)
        }
        let center = frame.centerX ?? levels[.hip].map { ($0.left + $0.right) / 2 * w } ?? w / 2
        let span = armSpan(frame.mask, top: top, height: floor - top, center: Int(center))
        return FrameReading(top: Double(top) / h, floor: Double(floor) / h, centerX: center / w, levels: levels,
                            armSpan: span, joints: frame.joints,
                            armThickness: (span ?? 0) >= 0.7 ? armThickness(frame.mask, top: top, height: floor - top, center: Int(center)) : nil,
                            outline: outline(frame.mask, top: top, floor: floor))
    }

    /// Leftmost and rightmost person pixel on about 70 evenly spaced rows.
    func outline(_ mask: BinaryMask, top: Int, floor: Int) -> [OutlineRow] {
        let step = max(1, (floor - top) / 70)
        let w = Double(mask.width), h = Double(mask.height)
        return stride(from: top, through: floor, by: step).compactMap { y in
            let runs = mask.runs(inRow: y)
            guard let first = runs.first, let last = runs.last else { return nil }
            return OutlineRow(y: Double(y) / h, left: Double(first.lowerBound) / w, right: Double(last.upperBound) / w)
        }
    }

    /// Vertical thickness of each outstretched arm halfway along the upper arm (21.5% of
    /// stature out from the body centre, at shoulder height), over stature, the thinner of
    /// the two sides. Masks have square pixels (see `BinaryMask.matchingAspect`).
    func armThickness(_ mask: BinaryMask, top: Int, height: Int, center: Int) -> Double? {
        let shoulderRow = top + height * 19 / 100
        let window = height * 7 / 100
        let sides = [-1, 1].compactMap { side -> Double? in
            let x = center + side * height * 215 / 1000
            guard x >= 0, x < mask.width else { return nil }
            // The arm's run in this column nearest the shoulder line.
            var best: Range<Int>?
            var y = shoulderRow - window
            while y <= shoulderRow + window {
                guard mask[x, y] else { y += 1; continue }
                let start = y
                while y <= shoulderRow + 2 * window, mask[x, y] { y += 1 }
                let run = start..<y
                if best.map({ abs(($0.lowerBound + $0.upperBound) / 2 - shoulderRow) }) ?? Int.max
                    > abs((start + y) / 2 - shoulderRow) { best = run }
            }
            return best.map { Double($0.count) / Double(height) }
        }
        // The thinner side: a bent or lowered arm only ever reads thicker.
        return sides.min()
    }

    /// Widest run through the body centre across the shoulder band (12–28% of body
    /// height below the top of the head), over body height. Pixels are converted to the
    /// vertical scale, since masks may not keep the camera frame's aspect ratio.
    func armSpan(_ mask: BinaryMask, top: Int, height: Int, center: Int, frameAspect: Double = 9.0 / 16.0) -> Double? {
        guard height > 0 else { return nil }
        let rows = (top + height * 12 / 100)...(top + height * 28 / 100)
        let widest = rows.compactMap { y in mask.run(inRow: y, containing: center)?.count }.max()
        guard let widest else { return nil }
        // Normalised x spans frameAspect as much distance as normalised y.
        let widthUnits = Double(widest) / Double(mask.width) * frameAspect
        let heightUnits = Double(height) / Double(mask.height)
        return widthUnits / heightUnits
    }

    /// Mean over angle bins, each bin weighted equally. `nil` when the turn covered too
    /// few directions to balance; the caller then uses the plain mean.
    static func angleBalancedMean(_ samples: [(width: Double, angle: Double?)]) -> Double? {
        var bins = [[Double]](repeating: [], count: angleBins)
        for sample in samples {
            guard let angle = sample.angle else { continue }
            bins[angleBin(angle)].append(sample.width)
        }
        let means = bins.filter { !$0.isEmpty }.map { $0.reduce(0, +) / Double($0.count) }
        guard means.count >= angleBins - 1 else { return nil }
        return means.reduce(0, +) / Double(means.count)
    }

    public static func angleBin(_ angle: Double) -> Int {
        min(angleBins - 1, max(0, Int(angle / 90 * Double(angleBins))))
    }

    private func levelReading(_ frame: RotationFrame, top: Int, height: Int, fraction: Double, heightCm: Double) -> LevelReading? {
        let mask = frame.mask
        let y = top + Int((fraction * Double(height)).rounded())
        let center = Int((frame.centerX ?? Double(rowCenter(mask, y: y) ?? -1)).rounded())
        guard center >= 0, let run = mask.run(inRow: y, containing: center) ?? nearestRun(mask, y: y, to: center),
              run.count >= minRowPixels else { return nil }
        let w = Double(mask.width)
        return LevelReading(y: Double(y) / Double(mask.height), left: Double(run.lowerBound) / w,
                            right: Double(run.upperBound) / w, widthCm: Double(run.count) * heightCm / Double(height))
    }

    /// Drops widths well above their neighbours (an arm touching the body for a few frames).
    func removeSpikes(_ widths: [Double]) -> [Double] {
        keptIndices(widths).map { widths[$0] }
    }

    private func keptIndices(_ widths: [Double]) -> [Int] {
        guard widths.count >= 5 else { return Array(widths.indices) }
        return widths.indices.filter { i in
            let lo = max(0, i - 6), hi = min(widths.count - 1, i + 6)
            let neighbourhood = widths[lo...hi].sorted()
            let median = neighbourhood[neighbourhood.count / 2]
            return widths[i] <= spikeFactor * median
        }
    }

    private func rowCenter(_ mask: BinaryMask, y: Int) -> Int? {
        let runs = mask.runs(inRow: y)
        guard let widest = runs.max(by: { $0.count < $1.count }) else { return nil }
        return (widest.lowerBound + widest.upperBound) / 2
    }

    private func nearestRun(_ mask: BinaryMask, y: Int, to x: Int) -> Range<Int>? {
        mask.runs(inRow: y).min { abs(($0.lowerBound + $0.upperBound) / 2 - x) < abs(($1.lowerBound + $1.upperBound) / 2 - x) }
    }

    private func verticalExtent(_ mask: BinaryMask) -> (Int, Int)? {
        func count(_ y: Int) -> Int { mask.runs(inRow: y).reduce(0) { $0 + $1.count } }
        guard let top = (0..<mask.height).first(where: { count($0) >= minRowPixels }),
              let floor = (0..<mask.height).reversed().first(where: { count($0) >= minRowPixels }),
              floor > top else { return nil }
        return (top, floor)
    }
}

private extension Double {
    var squared: Double { self * self }
}
