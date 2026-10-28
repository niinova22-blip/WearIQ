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
}

public struct BodyProfile: Codable, Hashable, Sendable {
    public var values: [BodyDimension: MeasuredValue]
    public var createdAt: Date
    public var weightKg: Double?
    public var sex: BodySex?

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
}
