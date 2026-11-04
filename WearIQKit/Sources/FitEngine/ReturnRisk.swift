import Foundation
import WearIQCore

/// How likely an order in the recommended size is to go back, from what the analysis
/// itself knows: how sure it is, whether any size fits where it matters, whether the
/// deciding measurement was only estimated. It never claims more than the analysis does.
///
/// Garments that can't be returned (swimwear, underwear: hygiene rules) are judged more
/// strictly, because a wrong size there can't be fixed by sending it back.
public struct ReturnRisk: Sendable, Equatable {
    public enum Level: String, Sendable, Comparable, CaseIterable {
        case low, medium, high

        private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    }

    /// Why the risk isn't low, most important first. The app words them.
    public enum Reason: String, Sendable, CaseIterable {
        /// The chart is missing what decides the size.
        case insufficientData
        /// No size fits at the chest (tops) or the waist (bottoms).
        case noSizeFits
        /// Two neighbouring sizes are too close to call.
        case betweenSizes
        /// The deciding measurement is an estimate from height and weight.
        case fromEstimates
        /// The recommended size is clearly off somewhere that matters.
        case criticalRegionOff
        /// Off somewhere less important (length, sleeves).
        case otherRegionOff
        /// The engine's own confidence is low.
        case lowConfidence
        /// The engine's own confidence is medium.
        case mediumConfidence
    }

    public var level: Level
    public var reasons: [Reason]
    /// Hygiene rules usually forbid returning it once opened.
    public var nonReturnable: Bool

    public init(level: Level, reasons: [Reason], nonReturnable: Bool) {
        self.level = level
        self.reasons = reasons
        self.nonReturnable = nonReturnable
    }

    /// The risk for buying `size` (the recommended one when nil).
    public static func assess(_ analysis: FitAnalysis, size: String? = nil, category: GarmentCategory?,
                              productName: String?) -> ReturnRisk {
        let nonReturnable = NonReturnable.isHygieneItem(name: productName)
        var level = Level.low
        var reasons: [Reason] = []
        func raise(_ to: Level, _ reason: Reason) {
            level = max(level, to)
            if !reasons.contains(reason) { reasons.append(reason) }
        }

        let recommended = analysis.recommendedSize?.label
        let chosen = size ?? recommended
        switch analysis.recommendation {
        case .insufficientData:
            raise(.high, .insufficientData)
        case .between:
            raise(.medium, .betweenSizes)
        case let .size(_, confidence):
            switch confidence {
            case .high: break
            case .medium: raise(.medium, .mediumConfidence)
            case .low: raise(.high, .lowConfidence)
            }
        }
        if analysis.noSizeFits != nil { raise(.high, .noSizeFits) }
        if analysis.fromEstimates == true { raise(.medium, .fromEstimates) }

        if let chosen, let fit = analysis.sizes.first(where: { $0.label == chosen }) {
            let critical: Set<FitRegion> = category?.isBottom == true ? [.waist, .hip] : [.chest]
            for region in fit.regions where region.missing == nil {
                switch region.severity {
                case .major where critical.contains(region.region):
                    raise(.high, .criticalRegionOff)
                case .major:
                    raise(.medium, .otherRegionOff)
                case .minor where critical.contains(region.region):
                    raise(.medium, .criticalRegionOff)
                default:
                    break
                }
            }
            // Choosing a size other than the advice is the shopper's call; its own
            // regions above already say how it sits.
        }

        // Nothing to fix by sending it back: anything short of a sure fit is a warning.
        if nonReturnable, level == .medium { level = .high }
        reasons.sort { Reason.allCases.firstIndex(of: $0)! < Reason.allCases.firstIndex(of: $1)! }
        return ReturnRisk(level: level, reasons: reasons, nonReturnable: nonReturnable)
    }
}

/// Garments stores usually won't take back once the hygiene seal is broken.
public enum NonReturnable {
    /// Whole words (Turkish and English) that name such garments.
    static let words: Set<String> = [
        "mayo", "mayosu", "bikini", "bikinisi", "haşema", "hasema", "tankini", "monokini",
        "iççamaşırı", "külot", "külotu", "kulot", "boxer", "boxerı", "sütyen", "sütyeni", "sutyen",
        "jartiyer", "tanga", "korse", "korsesi", "babydoll",
        "swimsuit", "swimwear", "swimming", "trunks", "underwear", "briefs", "brief", "panties", "panty",
        "bra", "bralette", "lingerie", "thong", "shapewear", "corset",
    ]
    /// Two-word names.
    static let phrases: [String] = [
        "iç çamaşırı", "ic camasiri", "deniz şortu", "deniz sortu", "yüzme şortu", "swim shorts",
        "swim trunks", "boxer brief",
    ]
    /// Look-alikes that are ordinary clothes.
    static let exceptions: [String] = [
        "slip elbise", "slip dress",
    ]

    public static func isHygieneItem(name: String?) -> Bool {
        guard let name else { return false }
        let text = name.lowercased(with: Locale(identifier: "tr_TR"))
        if exceptions.contains(where: text.contains) { return false }
        if phrases.contains(where: text.contains) { return true }
        let tokens = text.split { !$0.isLetter }.map(String.init)
        return tokens.contains { words.contains($0) }
    }
}
