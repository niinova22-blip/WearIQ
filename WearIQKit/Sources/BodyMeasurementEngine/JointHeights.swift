import Foundation
import WearIQCore

/// Where Vision's body joints sit as a fraction of stature, from ANSUR II landmark heights
/// (6,068 adults; each ratio varies by about 1% of stature between people):
/// ankle ≈ lateral malleolus 0.040, knee ≈ femoral epicondyle 0.279, hip joint ≈ just
/// above the trochanterion (0.513) 0.52, shoulder joint centre a little below the
/// acromion (0.820) 0.80, neck ≈ suprasternale 0.818.
///
/// Fitting these to the detected joints gives the person's stature and floor in pixels
/// from the skeleton alone, so lengths measured between joints don't depend on how far
/// the person mask reaches (hair, shadows, loose clothes).
public enum JointHeights {
    static let ratios: [BodyJoint: Double] = [
        .leftAnkle: 0.040, .rightAnkle: 0.040,
        .leftKnee: 0.279, .rightKnee: 0.279,
        .leftHip: 0.52, .rightHip: 0.52, .root: 0.52,
        .leftShoulder: 0.80, .rightShoulder: 0.80,
        .neck: 0.818,
    ]

    /// Fraction of stature for the levels where girths are measured (ANSUR II, sexes
    /// pooled): chest at nipple height 0.728, waist at the navel 0.601, hips at the
    /// buttocks' fullest point 0.507.
    public static let levelRatios: [BodyLevel: Double] = [.chest: 0.728, .waist: 0.601, .hip: 0.507]

    public struct Fit: Sendable, Equatable {
        /// Image row of the floor (y grows downwards).
        public var floorY: Double
        /// Stature in pixels.
        public var staturePx: Double

        /// Image row at a given fraction of stature above the floor.
        public func row(atRatio ratio: Double) -> Double { floorY - ratio * staturePx }
        /// Fraction of stature above the floor of an image row.
        public func ratio(ofRow y: Double) -> Double { (floorY - y) / staturePx }
    }

    /// Least-squares fit of y = floor − ratio × stature over the detected joints. Needs
    /// joints from the lower legs and the shoulders so the fit spans most of the body.
    public static func fit(_ joints: [BodyJoint: Point2D]) -> Fit? {
        let points = joints.compactMap { joint, p in ratios[joint].map { (r: $0, y: p.y) } }
        guard let lowest = points.map(\.r).min(), let highest = points.map(\.r).max(),
              lowest <= 0.3, highest >= 0.79, points.count >= 3 else { return nil }
        let n = Double(points.count)
        let mr = points.map(\.r).reduce(0, +) / n
        let my = points.map(\.y).reduce(0, +) / n
        let sxy = points.map { ($0.r - mr) * ($0.y - my) }.reduce(0, +)
        let sxx = points.map { ($0.r - mr) * ($0.r - mr) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        guard slope < 0 else { return nil }
        return Fit(floorY: my - slope * mr, staturePx: -slope)
    }
}
