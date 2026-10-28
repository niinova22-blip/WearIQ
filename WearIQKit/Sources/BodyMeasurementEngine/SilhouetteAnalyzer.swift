import Foundation

/// A person segmentation mask, row-major, y grows downwards. `true` = person.
public struct BinaryMask: Sendable {
    public let width: Int
    public let height: Int
    private let bits: [Bool]

    public init(width: Int, height: Int, bits: [Bool]) {
        precondition(bits.count == width * height)
        self.width = width
        self.height = height
        self.bits = bits
    }

    /// Builds a mask from 8-bit confidence values (e.g. Vision's OneComponent8 output).
    public init(width: Int, height: Int, bytesPerRow: Int, bytes: UnsafeRawBufferPointer, threshold: UInt8 = 128) {
        var bits = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width where bytes[row + x] >= threshold {
                bits[y * width + x] = true
            }
        }
        self.init(width: width, height: height, bits: bits)
    }

    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bits[y * width + x]
    }

    /// Contiguous person runs in a row as half-open x ranges.
    func runs(inRow y: Int) -> [Range<Int>] {
        guard y >= 0, y < height else { return [] }
        var result: [Range<Int>] = []
        var start: Int?
        for x in 0..<width {
            if self[x, y] {
                if start == nil { start = x }
            } else if let s = start {
                result.append(s..<x)
                start = nil
            }
        }
        if let s = start { result.append(s..<width) }
        return result
    }

    func run(inRow y: Int, containing x: Int) -> Range<Int>? {
        runs(inRow: y).first { $0.contains(x) }
    }
}

public enum SilhouetteError: Error, Equatable {
    case noPerson
    case missingJoints([BodyJoint])
}

/// Finds the body levels (chest, waist, hip, thigh) on segmentation masks.
///
/// Front photo: the user stands facing the camera with arms held slightly away from
/// the body (A-pose), so torso rows aren't widened by the arms. Side photo: levels are
/// placed at the same relative height as on the front photo.
public struct SilhouetteAnalyzer: Sendable {
    /// Minimum pixels in a row to count as body (filters segmentation noise).
    public var minRowPixels = 3

    public init() {}

    /// `joints` must be in mask pixel coordinates (y down).
    public func analyzeFront(mask: BinaryMask, joints: [BodyJoint: Point2D]) throws -> ScanObservation {
        let (top, floor) = try verticalExtent(mask)
        let required: [BodyJoint] = [.leftShoulder, .rightShoulder, .root]
        let missing = required.filter { joints[$0] == nil }
        guard missing.isEmpty, let ls = joints[.leftShoulder], let rs = joints[.rightShoulder], let root = joints[.root] else {
            throw SilhouetteError.missingJoints(missing)
        }
        let centerX = Int(root.x.rounded())
        let shoulderY = (ls.y + rs.y) / 2
        let torso = root.y - shoulderY
        guard torso > 0 else { throw SilhouetteError.missingJoints([.root]) }
        let kneeY = [joints[.leftKnee], joints[.rightKnee]].compactMap { $0?.y }.min() ?? (root.y + torso * 0.9)

        func centerWidth(_ y: Int) -> Int { mask.run(inRow: y, containing: centerX)?.count ?? 0 }

        var levels: [BodyLevel: LevelSample] = [:]

        let chestY = Int((shoulderY + 0.30 * torso).rounded())
        levels[.chest] = LevelSample(y: Double(chestY), extentPx: Double(centerWidth(chestY)))

        // Narrowest torso row between lower chest and the hip joints.
        let waistRange = Int(shoulderY + 0.45 * torso)...Int(root.y - 0.05 * torso)
        if let waistY = waistRange.filter({ centerWidth($0) > 0 }).min(by: { centerWidth($0) < centerWidth($1) }) {
            levels[.waist] = LevelSample(y: Double(waistY), extentPx: Double(centerWidth(waistY)))
        }

        // The crotch is the first row below the hip joint where the centre column is empty.
        let crotchY = (Int(root.y)...min(Int(kneeY), mask.height - 1)).first { y in
            !(-2...2).contains { mask[centerX + $0, y] }
        }

        // Widest row between the hip joints and the crotch.
        let hipEnd = crotchY.map { $0 - 1 } ?? Int(root.y + 0.3 * (kneeY - root.y))
        if hipEnd > Int(root.y),
           let hipY = (Int(root.y)...hipEnd).max(by: { centerWidth($0) < centerWidth($1) }) {
            levels[.hip] = LevelSample(y: Double(hipY), extentPx: Double(centerWidth(hipY)))
        }

        // Upper thigh just below the crotch; average the two legs.
        if let crotchY {
            let thighY = crotchY + max(2, Int(0.03 * Double(floor - top)))
            let legs = mask.runs(inRow: thighY).map(\.count).sorted(by: >)
            if legs.count >= 2 {
                levels[.thigh] = LevelSample(y: Double(thighY), extentPx: Double(legs[0] + legs[1]) / 2)
            }
        }

        // Arms touching the body widen the torso rows. The shoulder joints bound how wide
        // a torso can be; wider rows are dropped and left to the estimate.
        let shoulderSpan = ls.distance(to: rs)
        let maxRatio: [BodyLevel: Double] = [.chest: 1.25, .waist: 1.2, .hip: 1.35]
        for (level, ratio) in maxRatio {
            if let sample = levels[level], sample.extentPx > ratio * shoulderSpan { levels[level] = nil }
        }

        return ScanObservation(personHeightPx: Double(floor - top), floorY: Double(floor),
                               joints: joints, levels: levels, crotchY: crotchY.map(Double.init))
    }

    /// Measures body depth on the side photo at the front photo's relative heights.
    public func analyzeSide(mask: BinaryMask, front: ScanObservation) throws -> ScanObservation {
        let (top, floor) = try verticalExtent(mask)
        let frontTop = front.floorY - front.personHeightPx
        let height = Double(floor - top)
        var levels: [BodyLevel: LevelSample] = [:]
        for (level, sample) in front.levels {
            let fraction = (sample.y - frontTop) / front.personHeightPx
            let y = Int((Double(top) + fraction * height).rounded())
            // Arms hang beside the body in profile; the widest run is the torso/leg.
            if let widest = mask.runs(inRow: y).map(\.count).max() {
                levels[level] = LevelSample(y: Double(y), extentPx: Double(widest))
            }
        }
        return ScanObservation(personHeightPx: height, floorY: Double(floor), joints: [:], levels: levels)
    }

    private func verticalExtent(_ mask: BinaryMask) throws -> (top: Int, floor: Int) {
        func rowCount(_ y: Int) -> Int { mask.runs(inRow: y).reduce(0) { $0 + $1.count } }
        guard let top = (0..<mask.height).first(where: { rowCount($0) >= minRowPixels }),
              let floor = (0..<mask.height).reversed().first(where: { rowCount($0) >= minRowPixels }),
              floor > top else { throw SilhouetteError.noPerson }
        return (top, floor)
    }
}
