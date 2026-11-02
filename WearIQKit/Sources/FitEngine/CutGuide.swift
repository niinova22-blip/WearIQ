import Foundation
import WearIQCore

/// What a garment's cut means for how it sits on this body, and what to choose for a
/// different look. An oversized T-shirt is meant to drop at the shoulder and hang
/// roomy: the right size for it is the one whose room is the cut's, and someone who
/// doesn't want that look should pick a regular fit rather than size down until the
/// oversize is gone. Skinny jeans sit close by design, wide-leg trousers are roomy by
/// design; the size is still chosen by the waist and seat.
///
/// Returns codes and numbers; the app words them.
public struct CutNote: Equatable, Sendable {
    public enum Cut: String, Sendable {
        case oversizedTop, relaxedTop, slimTop
        case skinnyLeg, slimLeg, straightLeg, wideLeg, flareLeg, taperedLeg
    }

    public var cut: Cut
    /// The size of this garment that suits the body in this cut (the recommendation).
    public var size: String?
    /// Oversized tops: how far each shoulder seam sits down the arm in that size, cm.
    public var shoulderDropCm: Double?
    /// A smaller size of this same garment that is still within the cut's range but
    /// less pronounced (oversized → a size down that is merely relaxed).
    public var subtlerSize: String?
    /// For the other look, what to look for on another product's size chart: a garment
    /// chest (tops) or thigh (trousers) in this range, cm, full girth.
    public var alternativeChestCm: ClosedRange<Double>?
    public var alternativeThighCm: ClosedRange<Double>?
    /// Skinny without stretch in the fabric: the close cut has nothing to give.
    public var rigidSkinny = false

    public init(cut: Cut) { self.cut = cut }
}

public enum CutGuide {
    /// The note for this garment, or nil for a regular cut that needs no explaining.
    public static func note(for spec: GarmentSpec, body: BodyProfile, analysis: FitAnalysis) -> CutNote? {
        let recommended = analysis.recommendedSize?.label
        if spec.category.isBottom {
            return legNote(spec, body: body, recommended: recommended)
        }
        guard spec.category != .coat, spec.category != .dress else { return nil }
        let cut: CutNote.Cut
        switch spec.fitStyle {
        case .oversized: cut = .oversizedTop
        case .relaxed: cut = .relaxedTop
        case .slim: cut = .slimTop
        case .regular: return nil
        }
        var note = CutNote(cut: cut)
        note.size = recommended
        if let chest = body[.chest]?.cm {
            // A regular fit is cut 9–16 cm round the chest over the body.
            note.alternativeChestCm = (chest + 9).rounded()...(chest + 16).rounded()
        }
        guard cut == .oversizedTop else { return note }
        let size = spec.sizes.first { $0.label == recommended }
        if spec.chartKind == .garment, let g = size?.values[.shoulderWidth]?.cm, let b = body[.shoulderWidth] {
            note.shoulderDropCm = max(0, (g - FitEngine.acrossBack(b).cm) / 2)
        } else {
            // Oversized cuts drop the seam about 3–4 cm per side.
            note.shoulderDropCm = 3.5
        }
        // A size down that is still roomy (relaxed: 14–24 cm over the chest) keeps the
        // cut's line with less volume.
        if spec.chartKind == .garment, let chest = body[.chest]?.cm,
           let index = spec.sizes.firstIndex(where: { $0.label == recommended }), index > 0 {
            let smaller = spec.sizes[index - 1]
            if let g = smaller.values[.chest]?.cm, (14...24).contains(g - chest) { note.subtlerSize = smaller.label }
        }
        return note
    }

    private static func legNote(_ spec: GarmentSpec, body: BodyProfile, recommended: String?) -> CutNote? {
        guard spec.category != .skirt else { return nil }
        let cut: CutNote.Cut
        switch spec.legCut {
        case .skinny: cut = .skinnyLeg
        case .slim: cut = .slimLeg
        case .straight: cut = .straightLeg
        case .wide: cut = .wideLeg
        case .flare: cut = .flareLeg
        case .tapered: cut = .taperedLeg
        case nil:
            switch spec.fitStyle {
            case .oversized: cut = .wideLeg
            case .slim: cut = .slimLeg
            default: return nil
            }
        }
        var note = CutNote(cut: cut)
        note.size = recommended
        if let thigh = body[.thigh]?.cm {
            // The other look's thigh, garment girth: a straight/regular leg for those that
            // find skinny or slim too close; a slim one for those who find wide too much.
            switch cut {
            case .skinnyLeg, .slimLeg, .taperedLeg, .flareLeg:
                note.alternativeThighCm = (thigh + 6).rounded()...(thigh + 12).rounded()
            case .straightLeg, .wideLeg:
                note.alternativeThighCm = (thigh + 3).rounded()...(thigh + 7).rounded()
            default:
                break
            }
        }
        note.rigidSkinny = cut == .skinnyLeg && spec.stretch == .none
        return note
    }
}
