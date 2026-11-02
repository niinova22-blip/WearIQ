import FitEngine
import SwiftData
import SwiftUI
import WearIQCore

/// How the garment's cut is meant to sit on this body, and what to choose for another
/// look: an oversized T-shirt drops at the shoulder by design, skinny jeans sit close by
/// design. The size shown is the one that suits the body in this cut.
struct CutCard: View {
    let spec: GarmentSpec?
    let analysis: FitAnalysis
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]

    var body: some View {
        if let spec, let profile = profiles.first?.profile,
           let note = CutGuide.note(for: spec, body: profile, analysis: analysis) {
            Card {
                Label(note.title, systemImage: note.symbol)
                    .font(.headline)
                Text(note.meaning)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let size = note.size {
                    Label(String(localized: "For this cut, size \(size) suits your measurements."), systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if let subtler = note.subtlerSize {
                    Label(String(localized: "For a less roomy look in the same style, size \(subtler) is still oversized, just less so."),
                          systemImage: "minus.magnifyingglass")
                        .font(.subheadline)
                }
                if let other = note.otherLook {
                    Label(other, systemImage: "arrow.triangle.branch")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if note.rigidSkinny {
                    Label("This fabric has no stretch, so a skinny leg can feel stiff. Between two sizes, take the larger one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

extension CutNote {
    var title: String {
        switch cut {
        case .oversizedTop: String(localized: "Oversized cut")
        case .relaxedTop: String(localized: "Relaxed cut")
        case .slimTop: String(localized: "Slim cut")
        case .skinnyLeg: String(localized: "Skinny leg")
        case .slimLeg: String(localized: "Slim leg")
        case .straightLeg: String(localized: "Straight leg")
        case .wideLeg: String(localized: "Wide leg")
        case .flareLeg: String(localized: "Flared leg")
        case .taperedLeg: String(localized: "Tapered leg")
        }
    }

    var symbol: String {
        switch cut {
        case .oversizedTop, .relaxedTop, .slimTop: "tshirt"
        default: "figure.walk"
        }
    }

    /// What the cut does on the body, in the cut's own terms.
    var meaning: String {
        switch cut {
        case .oversizedTop:
            if let drop = shoulderDropCm, drop >= 1 {
                String(localized: "Cut roomy on purpose: the shoulder seams sit about \(Int(drop.rounded())) cm down your arms and the body hangs loose. That is the style, not a size too big.")
            } else {
                String(localized: "Cut roomy on purpose: dropped shoulders and a loose body are the style, not a size too big.")
            }
        case .relaxedTop:
            String(localized: "Cut with more room than a regular fit, so it hangs easily from the shoulders by design.")
        case .slimTop:
            String(localized: "Cut close to the body by design: it follows your chest and waist.")
        case .skinnyLeg:
            String(localized: "Close to your legs from thigh to ankle by design. The size is chosen by your waist and hips, so it hugs without pinching.")
        case .slimLeg:
            String(localized: "Narrow legs that taper gently to a small hem.")
        case .straightLeg:
            String(localized: "The same width from the knee to the hem: roomier round the calves and ankles because of the cut, not the size.")
        case .wideLeg:
            String(localized: "Roomy legs that widen to the hem: the extra width is the style. The size is chosen by your waist and hips.")
        case .flareLeg:
            String(localized: "Close through the thigh and knee, opening out below the knee by design.")
        case .taperedLeg:
            String(localized: "Room at the seat and thighs, narrowing to the ankle by design.")
        }
    }

    /// What to choose instead for the other look.
    var otherLook: String? {
        let chest = alternativeChestCm.map { (Int($0.lowerBound), Int($0.upperBound)) }
        let thigh = alternativeThighCm.map { (Int($0.lowerBound), Int($0.upperBound)) }
        switch cut {
        case .oversizedTop:
            guard let c = chest else { return String(localized: "If you don't want an oversized look, choose a regular-fit top in your usual size.") }
            return String(localized: "If you don't want an oversized look, choose a regular-fit top whose chest measures \(c.0)–\(c.1) cm.")
        case .relaxedTop:
            guard let c = chest else { return nil }
            return String(localized: "If you'd rather it sat closer, choose a regular fit with a chest of \(c.0)–\(c.1) cm.")
        case .slimTop:
            guard let c = chest else { return nil }
            return String(localized: "For more room, choose a regular fit with a chest of \(c.0)–\(c.1) cm.")
        case .skinnyLeg:
            guard let c = thigh else { return String(localized: "If you don't want it this close at the legs, choose a slim or straight cut.") }
            return String(localized: "If you don't want it this close at the legs, choose a slim or straight cut whose thigh measures \(c.0)–\(c.1) cm.")
        case .slimLeg, .taperedLeg:
            guard let c = thigh else { return String(localized: "For more room below the knee, choose a straight leg.") }
            return String(localized: "For more room below the knee, choose a straight leg with a thigh of about \(c.0)–\(c.1) cm.")
        case .flareLeg:
            return String(localized: "For a leg without the flare, choose a straight cut.")
        case .straightLeg:
            guard let c = thigh else { return String(localized: "For a closer leg, choose a slim or skinny cut.") }
            return String(localized: "For a closer leg, choose a slim or skinny cut with a thigh of about \(c.0)–\(c.1) cm.")
        case .wideLeg:
            guard let c = thigh else { return String(localized: "For less volume, choose a straight or slim cut.") }
            return String(localized: "For less volume, choose a straight or slim cut with a thigh of about \(c.0)–\(c.1) cm.")
        }
    }
}

extension LegCut {
    var title: String {
        switch self {
        case .skinny: String(localized: "Skinny")
        case .slim: String(localized: "Slim")
        case .straight: String(localized: "Straight leg")
        case .wide: String(localized: "Wide leg")
        case .flare: String(localized: "Flare / bootcut")
        case .tapered: String(localized: "Tapered / jogger")
        }
    }
}
