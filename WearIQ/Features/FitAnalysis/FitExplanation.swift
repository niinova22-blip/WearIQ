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
    static func text(for analysis: FitAnalysis) -> String {
        var sentences: [String] = []
        switch analysis.recommendation {
        case let .insufficientData(missing):
            let names = missing.map(\.title).joined(separator: ", ")
            return String(localized: "We need the \(names) measurement for both you and the garment to recommend a size.")
        case let .between(smaller, larger):
            sentences.append(String(localized: "\(smaller) and \(larger) fit about equally well. Pick \(smaller) for a closer fit or \(larger) for more room."))
        case .size:
            break
        }

        if let best = analysis.recommendedSize {
            let good = best.regions.filter { $0.severity == .good }.map { $0.region.title.lowercased() }
            if !good.isEmpty {
                sentences.append(String(localized: "\(best.label) suits your \(good.joined(separator: ", ")) best."))
            }
            for r in best.regions where r.severity == .minor || r.severity == .major {
                let amount = r.offsetText.map { " (\($0))" } ?? ""
                sentences.append(String(localized: "\(r.region.title): \(r.verdict.title.lowercased())\(amount)."))
            }
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
