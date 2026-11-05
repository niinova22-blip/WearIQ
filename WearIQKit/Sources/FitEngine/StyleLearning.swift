import Foundation
import WearIQCore

/// "Learn your style": the user stands in front of the phone in clothes they love, and
/// the outline of those clothes, set against their measured body, says how they like
/// clothes to sit: close, regular, roomy or oversized on top, and below; which leg cut;
/// a skirt or dress and how long. The user confirms or corrects it; from then on every
/// check also says which size suits that style.
public enum StyleLearning {
    /// Widths read from the photo (cm, scaled by the person's height), and what was seen.
    public struct Observation: Sendable, Equatable {
        /// The outline's width through the torso's middle at the chest, waist and hips.
        public var chest: Double?
        public var waist: Double?
        public var hip: Double?
        /// One leg's width just under the seat, and low on the shin (the hem's room).
        public var thigh: Double?
        public var lowerLeg: Double?
        /// The legs aren't seen apart below the hips: a skirt or a dress.
        public var legsCovered: Bool
        /// Where the covering ends, as a fraction of height above the floor (a skirt's hem).
        public var hemHeight: Double?
        /// The top reaches below the hips without a separate bottom (a dress).
        public var onePiece: Bool

        public init(chest: Double? = nil, waist: Double? = nil, hip: Double? = nil, thigh: Double? = nil,
                    lowerLeg: Double? = nil, legsCovered: Bool = false, hemHeight: Double? = nil, onePiece: Bool = false) {
            self.chest = chest; self.waist = waist; self.hip = hip; self.thigh = thigh; self.lowerLeg = lowerLeg
            self.legsCovered = legsCovered; self.hemHeight = hemHeight; self.onePiece = onePiece
        }
    }

    public enum Length: String, Codable, Sendable { case mini, knee, midi, maxi }

    /// What the app concluded (and the user may correct).
    public struct Style: Codable, Sendable, Equatable {
        public var topFit: FitStyle
        public var bottomFit: FitStyle
        public var legCut: LegCut?
        public var wearsSkirts: Bool
        public var skirtLength: Length?
        /// The user said it's right (or corrected it); only then does it shape advice.
        public var confirmed: Bool

        public init(topFit: FitStyle, bottomFit: FitStyle, legCut: LegCut? = nil, wearsSkirts: Bool = false,
                    skirtLength: Length? = nil, confirmed: Bool = false) {
            self.topFit = topFit; self.bottomFit = bottomFit; self.legCut = legCut
            self.wearsSkirts = wearsSkirts; self.skirtLength = skirtLength; self.confirmed = confirmed
        }
    }

    /// A body's frontal width over its girth at each level: about an ellipse 1.25–1.35
    /// times as wide as deep at the chest, waist and hips; round for thigh and calf.
    static let frontalRatio: [BodyDimension: Double] = [.chest: 0.364, .waist: 0.355, .hip: 0.36, .thigh: 0.318, .calf: 0.318]

    /// How much wider than the body the outline is, as a fraction (0.1 = 10% wider).
    static func room(_ observed: Double?, _ d: BodyDimension, body: BodyProfile) -> Double? {
        guard let observed, observed > 0, let girth = body[d]?.cm, let ratio = frontalRatio[d] else { return nil }
        return observed / (girth * ratio) - 1
    }

    /// The fit a room stands for. Over a fitted body most of a regular garment's room is
    /// at the sides, which is what the photo sees.
    static func fit(_ room: Double) -> FitStyle {
        switch room {
        case ..<0.06: .slim
        case ..<0.16: .regular
        case ..<0.30: .relaxed
        default: .oversized
        }
    }

    public static func infer(_ o: Observation, body: BodyProfile) -> Style {
        let topRoom = [room(o.chest, .chest, body: body), room(o.waist, .waist, body: body)].compactMap { $0 }.max() ?? 0.1
        var style = Style(topFit: fit(topRoom), bottomFit: .regular)
        if o.legsCovered || o.onePiece {
            style.wearsSkirts = true
            if let hem = o.hemHeight {
                // Knee ≈ 0.285 of height, mid-calf ≈ 0.18, ankle ≈ 0.04 (ANSUR ratios).
                style.skirtLength = hem > 0.33 ? .mini : hem > 0.24 ? .knee : hem > 0.1 ? .midi : .maxi
            }
            let hipRoom = room(o.hip, .hip, body: body) ?? 0.1
            style.bottomFit = fit(hipRoom)
            return style
        }
        let thighRoom = room(o.thigh, .thigh, body: body)
        let seatRoom = room(o.hip, .hip, body: body)
        let bottomRoom = [thighRoom, seatRoom].compactMap { $0 }.max() ?? 0.1
        style.bottomFit = fit(bottomRoom)
        if let lower = room(o.lowerLeg, .calf, body: body) {
            let thigh = thighRoom ?? bottomRoom
            style.legCut = switch (thigh, lower) {
            case let (_, l) where l > 0.55: .wide
            case let (t, l) where l > t + 0.25: .flare
            case let (t, l) where l < 0.12 && t < 0.1: .skinny
            case let (t, l) where l < t - 0.12: .tapered
            case let (_, l) where l < 0.2: .slim
            default: .straight
            }
        }
        return style
    }

    /// The size for this style: the same chart judged as if the garment were cut the way
    /// the user likes to wear it. Nil when the style isn't confirmed, a body chart can't
    /// say it, or it's the size already recommended.
    public static func sizeForStyle(_ style: Style, spec: GarmentSpec, body: BodyProfile,
                                    analysis: FitAnalysis, engine: any FitAnalyzing = FitEngine()) -> (size: String, fit: FitStyle)? {
        guard style.confirmed else { return nil }
        let wanted = spec.category.isBottom ? style.bottomFit : style.topFit
        guard wanted != spec.fitStyle, let recommended = analysis.recommendedSize?.label else { return nil }
        var restyled = spec
        restyled.fitStyle = wanted
        let label: String
        switch engine.analyze(body: body, garment: restyled, preference: .asDesigned).recommendation {
        case let .size(l, _): label = l
        // Between two: the closer of them to what fits as designed is the subtler look.
        case let .between(smaller, larger): label = wanted == .slim ? larger : smaller
        case .insufficientData: return nil
        }
        guard label != recommended else { return nil }
        return (label, wanted)
    }
}
