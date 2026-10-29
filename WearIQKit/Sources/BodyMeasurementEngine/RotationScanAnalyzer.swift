import Foundation
import WearIQCore

/// One frame of the 360° turn: the person mask and, when detected, the hip centre.
public struct RotationFrame: Sendable {
    public var mask: BinaryMask
    /// Body centre column (root joint), if Vision found it in this frame.
    public var centerX: Double?
    public var time: Double

    public init(mask: BinaryMask, centerX: Double?, time: Double) {
        self.mask = mask
        self.centerX = centerX
        self.time = time
    }
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
public struct RotationScanAnalyzer: Sendable {
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
            var widths: [Double] = []
            for (frame, top, height) in usable {
                let y = top + Int((fraction * Double(height)).rounded())
                let center = Int((frame.centerX ?? Double(rowCenter(frame.mask, y: y) ?? -1)).rounded())
                guard center >= 0, let run = frame.mask.run(inRow: y, containing: center) ?? nearestRun(frame.mask, y: y, to: center),
                      run.count >= minRowPixels else { continue }
                widths.append(Double(run.count) * heightCm / Double(height))
            }
            let clean = removeSpikes(widths)
            // A real turn shows both the wide (front/back) and narrow (side) views.
            guard clean.count >= minimumFrames / 2, let lo = clean.min(), let hi = clean.max(), lo < 0.88 * hi else { continue }
            let mean = clean.reduce(0, +) / Double(clean.count)
            let sd = (clean.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(clean.count)).squareRoot()
            let girth = Double.pi * mean
            // Statistical error of the mean plus 2% for segmentation edges and uneven turning speed.
            let uncertainty = ((Double.pi * sd / Double(clean.count).squareRoot()).squared + (0.02 * girth).squared).squareRoot()
            result[level] = MeasuredValue(cm: girth, uncertaintyCm: uncertainty, source: .scan)
        }
        guard !result.isEmpty else { throw RotationScanError.incompleteTurn }
        return result
    }

    /// Drops widths well above their neighbours (an arm touching the body for a few frames).
    func removeSpikes(_ widths: [Double]) -> [Double] {
        guard widths.count >= 5 else { return widths }
        return widths.enumerated().compactMap { i, w in
            let lo = max(0, i - 6), hi = min(widths.count - 1, i + 6)
            let neighbourhood = widths[lo...hi].sorted()
            let median = neighbourhood[neighbourhood.count / 2]
            return w > spikeFactor * median ? nil : w
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
