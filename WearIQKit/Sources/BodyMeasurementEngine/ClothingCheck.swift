import Foundation
import WearIQCore

/// Spots clothing too loose to measure through, from the front stop's outline with the
/// arms held straight out, by comparing it with real bodies:
///
/// - Upper-arm thickness: NHANES 2017–March 2020 mid-upper-arm circumference of 6,000+
///   civilian adults, as diameter over stature, depends on BMI as below; 99.5% of people
///   are within 0.011 (men) / 0.013 (women) of it. A sweatshirt sleeve adds several cm.
/// - Waist over hip width seen from the front: ANSUR II waist and hip breadths; 99.5% are
///   within 0.12 (men) / 0.14 (women) of the BMI trend. A loose top hides the waist.
///
/// A margin on top of those limits keeps fitted clothes and unusual bodies from tripping it.
public enum ClothingCheck {
    public enum Finding: Equatable, Sendable {
        case looseSleeves
        case looseTop
    }

    public static func findings(armThickness: Double?, waistWidthCm: Double?, hipWidthCm: Double?,
                                bmi: Double, sex: BodySex?) -> [Finding] {
        var found: [Finding] = []
        let female = sex == .female
        if let arm = armThickness {
            let typical = female ? 0.02714 + 0.00126 * bmi : 0.02989 + 0.00115 * bmi
            if arm > typical + (female ? 0.0135 : 0.011) + 0.006 { found.append(.looseSleeves) }
        }
        if let waist = waistWidthCm, let hip = hipWidthCm, hip > 0 {
            let typical = female ? 0.6548 + 0.0075 * bmi : 0.6985 + 0.0088 * bmi
            if waist / hip > typical + (female ? 0.136 : 0.118) + 0.03 { found.append(.looseTop) }
        }
        return found
    }
}
