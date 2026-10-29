import FitEngine
import Foundation
import WearIQCore

extension FitRegion {
    var title: String {
        switch self {
        case .shoulder: String(localized: "Shoulders")
        case .sleeve: String(localized: "Sleeves")
        case .chest: String(localized: "Chest")
        case .waist: String(localized: "Waist")
        case .bodyLength: String(localized: "Length")
        case .hip: String(localized: "Hips")
        case .thigh: String(localized: "Thighs")
        case .inseam: String(localized: "Leg length")
        case .outseam: String(localized: "Outer leg length")
        }
    }
}

extension FitVerdict {
    var title: String {
        switch self {
        case .tight: String(localized: "Tight")
        case .slightlyTight: String(localized: "Slightly tight")
        case .ideal: String(localized: "Good fit")
        case .slightlyLoose: String(localized: "Slightly loose")
        case .loose: String(localized: "Loose")
        case .short: String(localized: "Short")
        case .long: String(localized: "Long")
        case .insufficientData: String(localized: "Not enough data")
        }
    }
}

extension RegionFit {
    /// "about 2–3 cm" for mismatches; nil when there is nothing to quantify.
    var offsetText: String? {
        guard let r = estimatedOffsetCm else { return nil }
        let lo = Int(r.lowerBound.rounded())
        let hi = Int(r.upperBound.rounded())
        return lo == hi ? String(localized: "about \(hi) cm") : String(localized: "about \(lo)–\(hi) cm")
    }

    var detailText: String {
        switch verdict {
        case .insufficientData:
            missing == .bodyMeasurement
                ? String(localized: "Your profile lacks this measurement")
                : String(localized: "The size chart lacks this measurement")
        default:
            [verdict.title, offsetText].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

extension SizeRecommendation {
    var headline: String {
        switch self {
        case let .size(label, _): String(localized: "Recommended size: \(label)")
        case let .between(smaller, larger): String(localized: "Between \(smaller) and \(larger)")
        case .insufficientData: String(localized: "Not enough data for a size recommendation")
        }
    }
}

/// Plain-language summary built only from the engine's results.
enum FitExplanation {
    /// "waist fits, hips fit, leg length about 5–8 cm long." for one size.
    static func regionSentence(_ size: SizeFit) -> String {
        let parts = size.regions.filter { $0.verdict != .insufficientData }.map { r -> String in
            let name = r.region.title.lowercased()
            guard r.severity != .good else { return String(localized: "\(name) fits") }
            let amount = r.offsetText.map { " (\($0))" } ?? ""
            return "\(name) \(r.verdict.title.lowercased())\(amount)"
        }
        return parts.joined(separator: ", ") + "."
    }

    static func text(for analysis: FitAnalysis) -> String {
        var sentences: [String] = []
        switch analysis.recommendation {
        case let .insufficientData(missing):
            let names = missing.map(\.title).joined(separator: ", ")
            return String(localized: "We need the \(names) measurement for both you and the garment to recommend a size.")
        case let .between(smaller, larger):
            sentences.append(String(localized: "\(smaller) and \(larger) fit about equally well. Pick \(smaller) for a closer fit or \(larger) for more room."))
            // Say how each of the two will fit, region by region.
            for label in [smaller, larger] {
                if let size = analysis.sizes.first(where: { $0.label == label }) {
                    sentences.append("\(label): " + regionSentence(size))
                }
            }
        case .size:
            break
        }

        if let best = analysis.recommendedSize {
            sentences.append("\(best.label): " + regionSentence(best))
            // Explain why the neighbouring smaller size lost, if it did on a key region.
            if let index = analysis.sizes.firstIndex(where: { $0.label == best.label }), index > 0 {
                let smaller = analysis.sizes[index - 1]
                if let tight = smaller.regions.first(where: { $0.verdict == .tight || $0.verdict == .slightlyTight }) {
                    sentences.append(String(localized: "\(smaller.label) would likely be tight in the \(tight.region.title.lowercased())."))
                }
            }
            if best.regions.contains(where: { $0.confidence == .low && $0.verdict != .insufficientData }) {
                sentences.append(String(localized: "Some of your measurements are estimates, so treat this as a guide."))
            }
        }
        return sentences.joined(separator: " ")
    }
}

extension FitExplanation {
    /// How one size will look and feel, in a sentence or two, built from the region results.
    /// A clearly loose body also drops the shoulder seam, so sleeves and length look longer
    /// than their numbers suggest; that is said in words, the numbers stay as measured.
    static func summary(for size: SizeFit, recommended: String?) -> String {
        func verdict(_ r: FitRegion) -> FitVerdict? {
            size.regions.first { $0.region == r && $0.verdict != .insufficientData }?.verdict
        }
        let girth = verdict(.chest) ?? verdict(.waist) ?? verdict(.hip)
        let sleeve = verdict(.sleeve)
        let length = verdict(.bodyLength) ?? verdict(.inseam)
        let isRecommended = size.label == recommended
        var parts: [String] = []

        switch girth {
        case .loose?:
            parts.append(String(localized: "Clearly roomy through the body."))
            if sleeve != .short || length != .short {
                parts.append(String(localized: "The shoulder seam will sit lower, so sleeves and length can look a little longer."))
            }
            parts.append(isRecommended || recommended == nil
                ? String(localized: "Good if you like an oversized look.")
                : String(localized: "Wearable if you like an oversized look; for a cleaner fit choose \(recommended!)."))
        case .slightlyLoose?:
            parts.append(String(localized: "A relaxed, comfortable fit with a little room."))
        case .tight?:
            parts.append(String(localized: "Tight through the body; it may pull when you move."))
            if let recommended, !isRecommended { parts.append(String(localized: "\(recommended) will be more comfortable.")) }
        case .slightlyTight?:
            parts.append(String(localized: "Close-fitting; fine if you like it snug."))
        default:
            parts.append(isRecommended ? String(localized: "Fits your body well.") : String(localized: "The body fits."))
        }

        switch (sleeve, length) {
        case (.short?, .short?): parts.append(String(localized: "Sleeves and length will be short."))
        case (.short?, _): parts.append(String(localized: "Sleeves will be a little short."))
        case (_, .short?): parts.append(String(localized: "It will be a little short in length."))
        case (_, .long?) where verdict(.inseam) == .long:
            let amount = size.regions.first { $0.region == .inseam }?.offsetText
            parts.append(amount.map { String(localized: "The legs will be long (\($0)); roll or hem them.") }
                ?? String(localized: "The legs will be a little long; roll or hem them."))
        case (.long?, _), (_, .long?):
            if girth != .loose { parts.append(String(localized: "A bit long; you may want to roll the sleeves or tuck it in.")) }
        default: break
        }
        return parts.joined(separator: " ")
    }
}

