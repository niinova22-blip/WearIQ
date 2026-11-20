import Foundation

public enum GarmentCategory: String, Codable, CaseIterable, Sendable {
    case shirt, tshirt, jacket, pants
    /// A long outer layer: overcoat, trench, parka. Hangs past the hips.
    case coat
    case dress, skirt
    /// Knitwear and sweatshirts: jumpers, hoodies, cardigans. Long sleeves, a knit.
    case sweater
    case shorts

    /// Worn on the upper body (a dress counts: it's sized by the chest).
    public var isTop: Bool { !isBottom }
    /// Worn from the waist down.
    public var isBottom: Bool { self == .pants || self == .skirt || self == .shorts }
    /// Goes over other clothes.
    public var isOuterwear: Bool { self == .jacket || self == .coat }
}

public enum FitStyle: String, Codable, CaseIterable, Sendable {
    case slim, regular, relaxed, oversized
}

/// How trouser legs are cut below the seat, which the fit name alone doesn't say: two
/// slim-fit jeans can be skinny to the ankle or straight from the knee. The leg's room
/// from the knee down is the cut's, not the size's.
public enum LegCut: String, Codable, CaseIterable, Sendable {
    /// Close from thigh to ankle (usually stretch denim).
    case skinny
    /// Narrow, tapering gently to a small hem.
    case slim
    /// The same width from the knee to the hem ("boru paça").
    case straight
    /// Roomy all the way down, widest at the hem (wide leg, palazzo, baggy).
    case wide
    /// Close through the knee, opening out below it (bootcut, flare).
    case flare
    /// Room at the seat and thigh, narrowing to a small or cuffed hem (jogger, carrot).
    case tapered

    /// The fit the cut implies when the product names no fit of its own.
    public var impliedFit: FitStyle {
        switch self {
        case .skinny, .slim, .flare: .slim
        case .straight, .tapered: .regular
        case .wide: .relaxed
        }
    }
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
    /// Trousers: the width round the hem ("paça açıklığı", "leg opening"), as a full
    /// circumference like the girths. Told, not judged: the app measures no ankle.
    case legOpening
    /// Trousers: crotch seam to the top of the waistband at the front ("ön ağ",
    /// "front rise"). How high the waist sits; compared with garments the user owns.
    case frontRise
}

extension GarmentDimension {
    /// Measured round the garment (or across it, doubled): the ones flat-lay charts halve.
    public var isGirth: Bool {
        switch self {
        case .chest, .waist, .hip, .thigh, .legOpening: true
        default: false
        }
    }

    /// Measured along the garment.
    public var isLength: Bool {
        switch self {
        case .bodyLength, .sleeveLength, .inseam, .outseam, .frontRise: true
        default: false
        }
    }
}

/// What a number on a product page measures. Mixing these up is how a size goes wrong:
/// a body's 84 cm waist and a garment's 84 cm waist are a size apart.
public enum MeasurementBasis: String, Codable, Sendable {
    /// The body a size is made for ("Vücut ölçüleri", "to fit").
    case body
    /// The finished garment, measured round ("Ürün ölçüleri").
    case garment
    /// The garment laid flat and measured across, so half a girth ("düz serim", "1/2").
    case flatLay
    /// The model in the photos ("Manken 1.85 boyunda, M beden giyiyor").
    case model
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
    /// Trousers and shorts: how the legs are cut. Nil when the product doesn't say (and
    /// in analyses saved before it was kept).
    public var legCut: LegCut?

    public init(
        category: GarmentCategory,
        fitStyle: FitStyle = .regular,
        stretch: FabricStretch = .none,
        thickness: FabricThickness = .thin,
        chartKind: SizeChartKind,
        sizes: [SizeEntry],
        legCut: LegCut? = nil
    ) {
        self.legCut = legCut
        self.category = category
        self.fitStyle = fitStyle
        self.stretch = stretch
        self.thickness = thickness
        self.chartKind = chartKind
        self.sizes = sizes
    }
}
