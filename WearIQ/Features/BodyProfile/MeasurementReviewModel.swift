import Foundation
import Observation
import WearIQCore

/// Lets the user check scanned values and replace any of them with tape-measure values.
@Observable
final class MeasurementReviewModel {
    private(set) var profile: BodyProfile

    /// Display order on the review screen.
    static let order: [BodyDimension] = [
        .height, .shoulderWidth, .chest, .waist, .hip, .thigh, .armLength, .torsoLength, .inseam, .outseam,
    ]

    /// Plausible adult ranges; anything outside is almost certainly a typo.
    static let validRange: [BodyDimension: ClosedRange<Double>] = [
        .height: 120...230, .shoulderWidth: 25...70, .armLength: 40...90, .chest: 60...180,
        .waist: 45...180, .hip: 60...190, .thigh: 30...110, .torsoLength: 30...75,
        .inseam: 50...105, .outseam: 70...135,
    ]

    init(profile: BodyProfile) {
        self.profile = profile
    }

    func value(_ d: BodyDimension) -> MeasuredValue? { profile[d] }

    enum EditError: Error, Equatable {
        case outOfRange(ClosedRange<Double>)
    }

    /// Replaces a value with a tape-measure value (high confidence).
    func setManual(_ d: BodyDimension, cm: Double) throws {
        if let range = Self.validRange[d], !range.contains(cm) { throw EditError.outOfRange(range) }
        // A tape value over a scanned one teaches later scans this person's offset.
        if let old = profile[d], old.source == .scan { TapeCalibration.record(d, scanned: old.cm, tape: cm) }
        profile[d] = .manual(cm)
    }

    func clear(_ d: BodyDimension) {
        guard d != .height else { return }
        profile[d] = nil
    }

    /// The fit engine can't recommend tops without chest or pants without waist.
    var missingEssentials: [BodyDimension] {
        [.height, .chest, .waist].filter { profile[$0] == nil }
    }

    var lowConfidence: [BodyDimension] {
        Self.order.filter { profile[$0]?.confidence == .low }
    }

    /// Values that came from height/weight statistics rather than the photos.
    var estimated: [BodyDimension] {
        Self.order.filter { profile[$0]?.source == .estimated }
    }

    var scanned: [BodyDimension] {
        Self.order.filter { profile[$0]?.source == .scan }
    }

    var canSave: Bool { profile[.height] != nil }

    func finalizedProfile(now: Date = Date()) -> BodyProfile {
        var p = profile
        p.createdAt = now
        return p
    }
}

extension BodyDimension {
    var title: String {
        switch self {
        case .height: String(localized: "Height")
        case .shoulderWidth: String(localized: "Shoulder width")
        case .armLength: String(localized: "Arm length")
        case .chest: String(localized: "Chest")
        case .waist: String(localized: "Waist")
        case .hip: String(localized: "Hip")
        case .thigh: String(localized: "Thigh")
        case .torsoLength: String(localized: "Torso length")
        case .inseam: String(localized: "Inseam")
        case .outseam: String(localized: "Outseam")
        }
    }

    var howToMeasure: String {
        switch self {
        case .height: String(localized: "Barefoot, back against a wall, from floor to the top of your head.")
        case .shoulderWidth: String(localized: "Across your back, from the outer edge of one shoulder bone to the other.")
        case .armLength: String(localized: "From the shoulder bone, over a slightly bent elbow, to the wrist bone.")
        case .chest: String(localized: "Around the fullest part of your chest, under the armpits, tape level.")
        case .waist: String(localized: "Around your natural waist, the narrowest part, without pulling in.")
        case .hip: String(localized: "Around the fullest part of your hips and seat, feet together.")
        case .thigh: String(localized: "Around the fullest part of one thigh, just below the crotch.")
        case .torsoLength: String(localized: "From the bone at the base of your neck down your back to your waist.")
        case .inseam: String(localized: "From the crotch down the inside of the leg to the floor, barefoot.")
        case .outseam: String(localized: "From your waist down the outside of the leg to the floor, barefoot.")
        }
    }
}

extension ConfidenceLevel {
    var title: String {
        switch self {
        case .high: String(localized: "High confidence")
        case .medium: String(localized: "Medium confidence")
        case .low: String(localized: "Low confidence")
        }
    }
}

extension MeasurementSource {
    var title: String {
        switch self {
        case .scan: String(localized: "Scanned")
        case .manual: String(localized: "Measured")
        case .userProvided: String(localized: "Entered")
        case .estimated: String(localized: "Estimated from height and weight")
        }
    }
}
