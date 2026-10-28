import Foundation

public enum GarmentCategory: String, Codable, CaseIterable, Sendable {
    case shirt, tshirt, jacket, pants

    public var isTop: Bool { self != .pants }
}

public enum FitStyle: String, Codable, CaseIterable, Sendable {
    case slim, regular, relaxed, oversized
}

public enum FabricStretch: String, Codable, CaseIterable, Sendable {
    case none, low, medium, high

    /// Fraction a girth can be stretched comfortably while worn.
    public var comfortableStretch: Double {
        switch self {
        case .none: 0
        case .low: 0.02
        case .medium: 0.05
        case .high: 0.10
        }
    }
}

public enum FabricThickness: String, Codable, CaseIterable, Sendable {
    case thin, medium, thick

    /// Extra girth ease (cm) needed because the fabric itself takes up space.
    public var extraEaseCm: Double {
        switch self {
        case .thin: 0
        case .medium: 1
        case .thick: 3
        }
    }
}

/// How the user likes clothes to sit, relative to the garment's intended fit.
public enum FitPreference: String, Codable, CaseIterable, Sendable {
    case snugger, asDesigned, looser
}

/// Measurements a brand publishes per size.
public enum GarmentDimension: String, Codable, CaseIterable, Sendable {
    case shoulderWidth
    case sleeveLength
    case chest      // circumference
    case waist      // circumference
    case hip        // circumference
    case thigh      // circumference
    case bodyLength // tops: garment length from neck point; pants: not used
    case inseam
    case outseam
}

/// Size charts come in two kinds; mixing them up is the most common sizing error.
public enum SizeChartKind: String, Codable, Sendable {
    /// "Fits a body with chest 96–100" – values are BODY measurements.
    case body
    /// Flat-lay / technical measurements of the garment itself.
    case garment
}

public struct SizeEntry: Codable, Hashable, Sendable {
    public var label: String
    /// Values are always normalised to centimetres, girths as full circumference.
    public var values: [GarmentDimension: MeasuredValue]

    public init(label: String, values: [GarmentDimension: MeasuredValue]) {
        self.label = label
        self.values = values
    }
}

public struct GarmentSpec: Codable, Hashable, Sendable {
    public var category: GarmentCategory
    public var fitStyle: FitStyle
    public var stretch: FabricStretch
    public var thickness: FabricThickness
    public var chartKind: SizeChartKind
    public var sizes: [SizeEntry]

    public init(
        category: GarmentCategory,
        fitStyle: FitStyle = .regular,
        stretch: FabricStretch = .none,
        thickness: FabricThickness = .thin,
        chartKind: SizeChartKind,
        sizes: [SizeEntry]
    ) {
        self.category = category
        self.fitStyle = fitStyle
        self.stretch = stretch
        self.thickness = thickness
        self.chartKind = chartKind
        self.sizes = sizes
    }
}
