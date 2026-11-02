import Foundation
import WearIQCore

/// One more photo after the turn, where the turn left a girth unsure: the user turns a
/// quarter to the right (the left side to the phone), arms out as in the turn, and holds
/// still for a moment. Side-on is the view the front photo can't give, the body's depth,
/// and a still is sharper than a frame of the moving turn (`StationScan.stills`).
public struct FollowUpShot: Equatable, Sendable {
    /// The level the turn was least sure of, for the voice to name.
    public var level: BodyLevel
    /// The stop to hold: 2, a quarter turn to the right from facing the phone.
    public var station: Int = 2

    /// How sure a girth must be to need no second look: ±2.5% (about 2 cm at the waist).
    public static let wantedRelativeUncertainty = 0.025

    public init(level: BodyLevel, station: Int = 2) {
        self.level = level
        self.station = station
    }

    /// The shot to take, or nil when the turn measured chest, waist and hips well. A level
    /// is unsure when the turn couldn't give it at all, when every frame of it couldn't be
    /// fitted, when that fit is loose, or when the fit and the eight stops disagree by more
    /// than 3%. The least sure one is named; on a tie the waist, then the chest, then the hips.
    public static func plan(_ scan: StationScan) -> FollowUpShot? {
        var stops = scan
        stops.everyFrame = [:]
        let byStops = stops.girths()
        var worst: (BodyLevel, Double)?
        for level in [BodyLevel.waist, .chest, .hip] where scan.levels.contains(level) {
            let doubt: Double
            if let fitted = scan.everyFrame[level] {
                let spread = fitted.uncertaintyCm / fitted.cm
                let disagreement = byStops[level].map { abs($0.cm - fitted.cm) / fitted.cm } ?? 0
                doubt = max(spread / wantedRelativeUncertainty, disagreement / 0.03)
            } else {
                doubt = byStops[level] == nil ? 10 : 2
            }
            if doubt > 1, doubt > (worst?.1 ?? 0) { worst = (level, doubt) }
        }
        return worst.map { FollowUpShot(level: $0.0) }
    }
}
