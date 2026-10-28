import WearIQCore

public enum FitRegion: String, Codable, CaseIterable, Sendable {
    case shoulder, sleeve, chest, waist, bodyLength
    case hip, thigh, inseam, outseam
}

public enum FitVerdict: String, Codable, Sendable {
    case tight, slightlyTight, ideal, slightlyLoose, loose
    case short, long
    case insufficientData
}

/// Drives the colour coding: good = green, minor = yellow, major = red, unknown = grey.
public enum FitSeverity: String, Codable, Sendable {
    case good, minor, major, unknown
}

public struct RegionFit: Codable, Hashable, Sendable {
    public var region: FitRegion
    public var verdict: FitVerdict
    public var severity: FitSeverity
    /// How far outside the comfortable range the garment is, as an uncertainty band
    /// (e.g. 2...3 → "about 2–3 cm long"). `nil` when ideal or no data.
    public var estimatedOffsetCm: ClosedRange<Double>?
    /// Probability (0–1) that this region actually falls in the comfortable range,
    /// given body and garment measurement uncertainty.
    public var probabilityIdeal: Double?
    public var confidence: ConfidenceLevel
    /// What's missing when verdict == .insufficientData.
    public var missing: MissingData?

    public enum MissingData: String, Codable, Sendable {
        case bodyMeasurement, garmentMeasurement
    }
}

public struct SizeFit: Codable, Hashable, Sendable {
    public var label: String
    public var regions: [RegionFit]
    /// Lower is better. Expected penalty integrated over measurement uncertainty.
    public var penalty: Double
    public var hasCriticalData: Bool

    public func region(_ r: FitRegion) -> RegionFit? { regions.first { $0.region == r } }
}

public enum SizeRecommendation: Codable, Hashable, Sendable {
    case size(label: String, confidence: ConfidenceLevel)
    /// Two neighbouring sizes score too close to call.
    case between(smaller: String, larger: String)
    case insufficientData(missing: [FitRegion])
}

public struct FitAnalysis: Codable, Hashable, Sendable {
    public var recommendation: SizeRecommendation
    /// In size chart order.
    public var sizes: [SizeFit]

    /// Sizes ordered from best to worst; the alternatives list on the result screen.
    public var ranked: [SizeFit] {
        sizes.filter(\.hasCriticalData).sorted { $0.penalty < $1.penalty }
    }

    public var recommendedSize: SizeFit? {
        guard case let .size(label, _) = recommendation else { return nil }
        return sizes.first { $0.label == label }
    }
}
