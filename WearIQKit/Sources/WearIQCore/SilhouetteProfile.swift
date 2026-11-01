import Foundation

/// One stop of the eight-stop turn reduced to numbers: the person's silhouette width at
/// fixed heights, in cm (scaled, like every turn measurement, by the typed height).
/// Kept so a second measuring method can run on exactly the scan the first one saw,
/// without keeping any picture of the person.
public struct StopProfile: Codable, Sendable, Equatable {
    /// 0–7: the stop, each 45° further round than the one before (0 facing the phone).
    public var station: Int
    /// Width of the run through the body's middle at `SilhouetteRows.torso`, nil where
    /// the row couldn't be read.
    public var torso: [Double?]
    /// At `SilhouetteRows.thigh`: each separate leg's width (two when the legs are seen
    /// apart, from the front or back), and the outer width of both legs together.
    public var legs: [[Double]]
    public var legsOuter: [Double?]

    public init(station: Int, torso: [Double?], legs: [[Double]], legsOuter: [Double?]) {
        self.station = station
        self.torso = torso
        self.legs = legs
        self.legsOuter = legsOuter
    }

    /// The median of several readings of the same stop, row by row.
    public static func median(_ readings: [StopProfile]) -> StopProfile? {
        guard let first = readings.first else { return nil }
        func mid(_ values: [Double]) -> Double? {
            let s = values.sorted()
            return s.isEmpty ? nil : s[s.count / 2]
        }
        let torso = first.torso.indices.map { i in mid(readings.compactMap { i < $0.torso.count ? $0.torso[i] : nil }) }
        let outer = first.legsOuter.indices.map { i in mid(readings.compactMap { i < $0.legsOuter.count ? $0.legsOuter[i] : nil }) }
        let legs = first.legs.indices.map { i -> [Double] in
            // The legs as most readings saw them (apart or together), each the median.
            let seen = readings.compactMap { i < $0.legs.count ? $0.legs[i] : nil }
            let counts = Dictionary(grouping: seen, by: \.count)
            guard let common = counts.max(by: { $0.value.count < $1.value.count })?.value, let n = common.first?.count else { return [] }
            return (0..<n).compactMap { k in mid(common.map { $0[k] }) }
        }
        return StopProfile(station: first.station, torso: torso, legs: legs, legsOuter: outer)
    }
}

/// The heights a `StopProfile` is read at, as fractions of stature below the top of
/// the head. The torso rows run from just below the outstretched arms (about 0.19–0.23
/// of stature down) to just above the crotch (about 0.53); the thigh rows just below it.
public enum SilhouetteRows {
    public static let torso: [Double] = stride(from: 0.27, through: 0.511, by: 0.01).map { ($0 * 1000).rounded() / 1000 }
    public static let thigh: [Double] = [0.57, 0.59, 0.61]
}

/// Where a measurement's value comes from, for saying how far it can be trusted.
public enum MeasurementProvenance: String, Codable, Sendable {
    /// Seen directly: the silhouettes or the skeleton cover it.
    case observed
    /// Read off the fitted body model where the camera doesn't see it directly (a
    /// collar girth, an upper arm): the model's shape statistics, guided by what was seen.
    case model
    /// From height, weight and sex alone.
    case prior
    /// Measured with a tape.
    case tape
}
