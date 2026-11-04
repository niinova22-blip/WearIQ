import Foundation
import WearIQCore

/// A weight reading (from Apple Health) that has moved away from the weight the body
/// profile was measured at, by enough to change girths.
///
/// The measured profile is never rewritten from it. The app suggests a rescan and, until
/// then, can use `estimatedProfile`: the measured girths moved by what the population
/// statistics say that weight change does, marked as estimates so no advice from them is
/// ever sure.
public struct WeightChange: Sendable, Equatable {
    public var fromKg: Double
    public var toKg: Double
    public var measuredAt: Date

    public var deltaKg: Double { toKg - fromKg }

    /// 3 kg, or 4% of the weight for heavier people: below it daily swings (water,
    /// meals) dominate and girths don't move enough to change a size.
    public static func threshold(forKg kg: Double) -> Double { max(3, kg * 0.04) }

    /// Nil unless the reading is newer than the profile and far enough from its weight.
    public static func check(profile: BodyProfile, currentKg: Double, measuredAt: Date) -> WeightChange? {
        guard let from = profile.weightKg, from > 0, currentKg > 0, measuredAt > profile.createdAt,
              abs(currentKg - from) >= threshold(forKg: from) else { return nil }
        return WeightChange(fromKg: from, toKg: currentKg, measuredAt: measuredAt)
    }

    /// Girths that follow weight. Lengths and the shoulder breadth don't.
    static let girths: [BodyDimension] = [.chest, .waist, .hip, .thigh, .neck, .upperArm, .forearm, .wrist, .knee, .calf, .ankle]

    /// How much each girth is expected to change, cm, from the height/weight models.
    public func expectedShifts(for profile: BodyProfile, prior: AnthropometricPrior = AnthropometricPrior()) -> [BodyDimension: Double] {
        guard let height = profile[.height]?.cm else { return [:] }
        let before = prior.estimate(heightCm: height, weightKg: fromKg, sex: profile.sex)
        let after = prior.estimate(heightCm: height, weightKg: toKg, sex: profile.sex)
        var shifts: [BodyDimension: Double] = [:]
        for d in Self.girths where profile[d] != nil {
            if let a = before[d]?.cm, let b = after[d]?.cm { shifts[d] = b - a }
        }
        return shifts
    }

    /// The profile with its girths moved by the expected shifts, as estimates whose
    /// uncertainty grows with the shift (people gain and lose in different places).
    public func estimatedProfile(from profile: BodyProfile, now: Date = Date(),
                                 prior: AnthropometricPrior = AnthropometricPrior()) -> BodyProfile {
        var updated = profile
        updated.createdAt = now
        updated.weightKg = toKg
        updated.assessments = nil
        updated.rejectedScans = nil
        for (d, shift) in expectedShifts(for: profile, prior: prior) {
            guard let old = profile[d] else { continue }
            let spread = (old.uncertaintyCm * old.uncertaintyCm + (0.5 * shift) * (0.5 * shift) + 1).squareRoot()
            updated[d] = MeasuredValue(cm: old.cm + shift, uncertaintyCm: spread, source: .estimated)
        }
        return updated
    }
}
