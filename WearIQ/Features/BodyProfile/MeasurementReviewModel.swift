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
    /// Shown below, estimated unless typed in.
    static let detailOrder: [BodyDimension] = BodyDimension.details

    /// Plausible adult ranges; anything outside is almost certainly a typo.
    static let validRange: [BodyDimension: ClosedRange<Double>] = [
        .height: 120...230, .shoulderWidth: 25...70, .armLength: 40...90, .chest: 60...180,
        .waist: 45...180, .hip: 60...190, .thigh: 30...110, .torsoLength: 30...75,
        .inseam: 50...105, .outseam: 70...135,
        .neck: 25...60, .upperArm: 18...55, .forearm: 15...45, .wrist: 12...25, .knee: 25...65,
        .calf: 25...60, .ankle: 16...35,
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
        profile.assessments?[d] = MeasurementAssessment(.manual(cm))
    }

    func clear(_ d: BodyDimension) {
        guard d != .height else { return }
        profile[d] = nil
        profile.assessments?[d] = nil
    }

    /// Where the clothes hid the body, loosest first.
    var clothingIssues: [(region: ClothingRegion, cover: ClothingCover)] {
        (profile.clothing ?? [:]).filter { $0.value > .fitted }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key.rawValue < $1.key.rawValue) }
            .map { ($0.key, $0.value) }
    }

    /// "81–89 cm" when the scan gives a range wider than a couple of centimetres.
    func range(_ d: BodyDimension) -> String? {
        guard let v = profile[d], v.source != .manual, v.source != .userProvided,
              let a = profile.assessment(d), a.high - a.low >= 2 else { return nil }
        return "\(Int(a.low.rounded()))–\(Int(a.high.rounded())) cm"
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
        case .neck: String(localized: "Neck")
        case .upperArm: String(localized: "Upper arm")
        case .forearm: String(localized: "Forearm")
        case .wrist: String(localized: "Wrist")
        case .knee: String(localized: "Knee")
        case .calf: String(localized: "Calf")
        case .ankle: String(localized: "Ankle")
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
        case .neck: String(localized: "Around the base of your neck, where a shirt collar sits.")
        case .upperArm: String(localized: "Around the fullest part of your upper arm, arm relaxed.")
        case .forearm: String(localized: "Around the fullest part of your forearm, arm relaxed.")
        case .wrist: String(localized: "Around your wrist, just above the wrist bone.")
        case .knee: String(localized: "Around your leg just above the kneecap, standing.")
        case .calf: String(localized: "Around the fullest part of your calf, standing.")
        case .ankle: String(localized: "Around the narrowest part of your leg above the ankle bone.")
        }
    }
}

extension ClothingCover {
    var title: String {
        switch self {
        case .skin: String(localized: "Skin or underwear")
        case .fitted: String(localized: "Fitted")
        case .regular: String(localized: "Regular fit")
        case .slightlyLoose: String(localized: "Slightly loose")
        case .loose: String(localized: "Loose")
        case .layered: String(localized: "Thick or layered")
        }
    }
}

extension ClothingRegion {
    var title: String {
        switch self {
        case .chest: String(localized: "Chest")
        case .waist: String(localized: "Waist")
        case .hips: String(localized: "Hips")
        case .arms: String(localized: "Arms")
        case .legs: String(localized: "Legs")
        }
    }

    /// What to change for a sharper value there on the next scan.
    var advice: String {
        switch self {
        case .chest: String(localized: "Your top is loose over the chest. A fitted top would measure it directly.")
        case .waist: String(localized: "Your top hides your waist. Tuck it in or pull it close to your body and scan again.")
        case .hips: String(localized: "Your trousers are loose at the hips. Fitted trousers or leggings would measure them directly.")
        case .arms: String(localized: "Your sleeves are loose. Short or fitted sleeves would help.")
        case .legs: String(localized: "Your trouser legs are loose. Fitted trousers or leggings would measure your thighs directly.")
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
