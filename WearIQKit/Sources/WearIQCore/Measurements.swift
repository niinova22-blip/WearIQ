import Foundation

/// Where a measurement came from. Manual (tape measure) values are trusted more than scans.
public enum MeasurementSource: String, Codable, Sendable {
    case scan
    case manual
    case userProvided   // e.g. height typed during onboarding
    case estimated      // predicted from height, weight and sex (population statistics)
}

/// Used only to pick the matching body-proportion statistics.
public enum BodySex: String, Codable, CaseIterable, Sendable {
    case male, female
}

/// A length in centimetres with an explicit uncertainty (approx. one standard deviation).
public struct MeasuredValue: Codable, Hashable, Sendable {
    public var cm: Double
    public var uncertaintyCm: Double
    public var source: MeasurementSource

    public init(cm: Double, uncertaintyCm: Double, source: MeasurementSource) {
        self.cm = cm
        self.uncertaintyCm = max(0, uncertaintyCm)
        self.source = source
    }

    public static func manual(_ cm: Double) -> MeasuredValue {
        MeasuredValue(cm: cm, uncertaintyCm: 1.0, source: .manual)
    }

    /// Coarse confidence bucket shown in the UI next to a value.
    public var confidence: ConfidenceLevel {
        ConfidenceLevel(relativeUncertainty: cm > 0 ? uncertaintyCm / cm : 1)
    }
}

public enum ConfidenceLevel: String, Codable, Sendable, Comparable {
    case low, medium, high

    public init(relativeUncertainty r: Double) {
        switch r {
        case ..<0.025: self = .high
        case ..<0.06: self = .medium
        default: self = .low
        }
    }

    private var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

public enum BodyDimension: String, Codable, CaseIterable, Sendable {
    case height
    case shoulderWidth
    case armLength
    case chest          // circumference
    case waist          // circumference
    case hip            // circumference
    case thigh          // circumference
    case torsoLength    // base of neck (C7) to waist
    case inseam
    case outseam        // waist to floor
    // Detail girths: too small or too hidden to see in the outline, so they come from
    // height/weight statistics unless measured by hand.
    case neck           // at the base, where a collar sits
    case upperArm       // relaxed, at the biceps
    case forearm
    case wrist
    case knee           // just above the kneecap
    case calf
    case ankle

    /// The ones the scan itself measures; the rest are estimated or typed in.
    public static let scanned: [BodyDimension] = [
        .height, .shoulderWidth, .armLength, .chest, .waist, .hip, .thigh, .torsoLength, .inseam, .outseam,
    ]
    public static let details: [BodyDimension] = [.neck, .upperArm, .forearm, .wrist, .knee, .calf, .ankle]
}

/// How much the clothes worn during a scan hide the body at one place, from skin or
/// skin-tight (the outline is the body) to thick or layered (the outline is mostly
/// clothes).
public enum ClothingCover: String, Codable, CaseIterable, Sendable, Comparable {
    case skin, fitted, regular, slightlyLoose, loose, layered

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// The parts of the body a scan judges the clothing on separately: a loose top over
/// leggings hides the waist but not the thighs.
public enum ClothingRegion: String, Codable, CaseIterable, Sendable {
    case chest, waist, hips, arms, legs

    /// The region whose clothing affects a measurement, if any. Lengths between joints
    /// and the shoulder breadth come from the skeleton, which clothes don't move much.
    public init?(_ d: BodyDimension) {
        switch d {
        case .chest: self = .chest
        case .waist: self = .waist
        case .hip: self = .hips
        case .thigh, .knee, .calf, .ankle: self = .legs
        case .upperArm, .forearm, .wrist: self = .arms
        case .height, .shoulderWidth, .armLength, .torsoLength, .inseam, .outseam, .neck: return nil
        }
    }
}

/// What is known about one measurement beyond its value: a range that should contain the
/// true value, how the clothes affected it, and whether the user confirmed it.
public struct MeasurementAssessment: Codable, Hashable, Sendable {
    /// Bounds of the 90% credible interval, cm.
    public var low: Double
    public var high: Double
    /// Clothing over the place it was measured, when the scan judged it.
    public var clothing: ClothingCover?
    /// The outline's reading minus the estimate: how much the clothes were taken to add.
    public var clothingEffectCm: Double?
    /// The user checked it with a tape measure or typed it in.
    public var verified: Bool

    public init(low: Double, high: Double, clothing: ClothingCover? = nil, clothingEffectCm: Double? = nil,
                verified: Bool = false) {
        self.low = min(low, high)
        self.high = max(low, high)
        self.clothing = clothing
        self.clothingEffectCm = clothingEffectCm
        self.verified = verified
    }

    /// A symmetric 90% interval around a value with a normal error.
    public init(_ v: MeasuredValue, clothing: ClothingCover? = nil, clothingEffectCm: Double? = nil) {
        self.init(low: v.cm - 1.645 * v.uncertaintyCm, high: v.cm + 1.645 * v.uncertaintyCm,
                  clothing: clothing, clothingEffectCm: clothingEffectCm, verified: v.source == .manual)
    }
}

public struct BodyProfile: Codable, Hashable, Sendable {
    public var values: [BodyDimension: MeasuredValue]
    public var createdAt: Date
    public var weightKg: Double?
    public var sex: BodySex?
    /// Scan readings so far from what height and weight allow that an estimate was used
    /// instead, kept so the review can show what the scan saw.
    public var rejectedScans: [BodyDimension: Double]?
    /// Stature in skeleton pixels over stature in mask pixels on the front photo; 1 when
    /// the joints and the outline agree. Kept to trace scale problems.
    public var skeletonToMaskRatio: Double?
    /// Per measurement: range, clothing effect and confirmation (scans after the
    /// clothing-aware engine; older profiles have none).
    public var assessments: [BodyDimension: MeasurementAssessment]?
    /// Clothing judged per body region during the scan.
    public var clothing: [ClothingRegion: ClothingCover]?

    public init(values: [BodyDimension: MeasuredValue] = [:], createdAt: Date = Date(),
                weightKg: Double? = nil, sex: BodySex? = nil) {
        self.values = values
        self.createdAt = createdAt
        self.weightKg = weightKg
        self.sex = sex
    }

    public subscript(_ d: BodyDimension) -> MeasuredValue? {
        get { values[d] }
        set { values[d] = newValue }
    }

    /// The stored assessment, or one derived from the value's uncertainty.
    public func assessment(_ d: BodyDimension) -> MeasurementAssessment? {
        if let stored = assessments?[d] {
            var a = stored
            if values[d]?.source == .manual { a.verified = true }
            return a
        }
        return values[d].map { MeasurementAssessment($0) }
    }
}
