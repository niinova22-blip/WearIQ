import Foundation

public struct Outfit: Hashable, Sendable {
    public var items: [WardrobeItem]
    /// 0–1, higher is better.
    public var score: Double
    public var reasons: [Reason]

    public enum Reason: Hashable, Sendable {
        case suitsOccasion
        case neutralBase
        case harmoniousColors(ColorFamily, ColorFamily)
        case favoriteColor(ColorFamily)
        case seasonAppropriate
        case goodFit
        case layeredForCold
    }
}

public protocol OutfitRecommending: Sendable {
    func outfits(from wardrobe: [WardrobeItem], occasion: Occasion, season: Season,
                 preferences: OutfitPreferences, limit: Int) -> [Outfit]
}

/// Rule-based outfit generator (first version). The protocol lets a Core ML ranker
/// replace or re-rank these candidates later without touching the UI.
public struct RuleBasedOutfitEngine: OutfitRecommending {
    /// Candidates kept per slot before combining, to bound the search.
    public var perSlotCandidates = 6

    public init() {}

    public func outfits(from wardrobe: [WardrobeItem], occasion: Occasion, season: Season,
                        preferences: OutfitPreferences, limit: Int = 5) -> [Outfit] {
        let usable = wardrobe.filter { item in
            item.seasons.contains(season)
                && !preferences.avoidedColors.contains(item.color)
                && styleScore(item, occasion) > 0
        }
        func best(_ c: WardrobeCategory) -> [WardrobeItem] {
            usable.filter { $0.category == c }
                .sorted { itemScore($0, occasion) > itemScore($1, occasion) || (itemScore($0, occasion) == itemScore($1, occasion) && $0.name < $1.name) }
                .prefix(perSlotCandidates).map { $0 }
        }

        let tops = best(.top), bottoms = best(.bottom), dresses = best(.dress)
        let outer = best(.outerwear), shoes = best(.shoes)
        let cold = season == .winter || season == .autumn

        var bases: [[WardrobeItem]] = []
        for t in tops { for b in bottoms { bases.append([t, b]) } }
        bases += dresses.map { [$0] }

        var results: [Outfit] = []
        for base in bases {
            // Outerwear is required when it's cold and available, optional otherwise.
            let outerOptions: [WardrobeItem?] = outer.isEmpty ? [nil] : (cold ? outer.map { $0 } : [nil] + outer.map { $0 })
            let shoeOptions: [WardrobeItem?] = shoes.isEmpty ? [nil] : shoes.map { $0 }
            for o in outerOptions {
                for s in shoeOptions {
                    let items = base + [o, s].compactMap { $0 }
                    results.append(evaluate(items, occasion: occasion, preferences: preferences, layered: cold && o != nil))
                }
            }
        }

        // Keep the best outfit per base so suggestions aren't five variations of one look.
        var seenBases = Set<[UUID]>()
        return results
            .sorted { $0.score > $1.score || ($0.score == $1.score && $0.items.map(\.name).joined() < $1.items.map(\.name).joined()) }
            .filter { outfit in
                let key = outfit.items.filter { [.top, .bottom, .dress].contains($0.category) }.map(\.id)
                return seenBases.insert(key).inserted
            }
            .prefix(limit).map { $0 }
    }

    // MARK: Scoring

    func styleScore(_ item: WardrobeItem, _ occasion: Occasion) -> Double {
        item.styles.compactMap { occasion.styleFit[$0] }.max() ?? 0
    }

    private func itemScore(_ item: WardrobeItem, _ occasion: Occasion) -> Double {
        styleScore(item, occasion) * 0.7 + (item.fitScore ?? 0.6) * 0.3
    }

    func evaluate(_ items: [WardrobeItem], occasion: Occasion, preferences: OutfitPreferences, layered: Bool) -> Outfit {
        var reasons: [Outfit.Reason] = [.suitsOccasion, .seasonAppropriate]
        let style = items.map { styleScore($0, occasion) }.reduce(0, +) / Double(items.count)
        let fits = items.compactMap(\.fitScore)
        let fit = fits.isEmpty ? 0.6 : fits.reduce(0, +) / Double(fits.count)
        if !fits.isEmpty, fit >= 0.8 { reasons.append(.goodFit) }

        let (harmony, colorReasons) = Self.colorHarmony(items.map(\.color))
        reasons += colorReasons

        let favorites = Set(items.map(\.color)).intersection(preferences.favoriteColors)
        let favoriteBonus = favorites.isEmpty ? 0 : 0.05
        reasons += favorites.sorted { $0.rawValue < $1.rawValue }.map(Outfit.Reason.favoriteColor)
        if layered { reasons.append(.layeredForCold) }

        let score = min(1, 0.45 * style + 0.35 * harmony + 0.2 * fit + favoriteBonus)
        return Outfit(items: items, score: score, reasons: reasons)
    }

    /// 0–1. Neutrals are free; one accent colour is ideal; two accents must be
    /// analogous (≤ 45°) or complementary (~180°); three or more accents clash.
    static func colorHarmony(_ colors: [ColorFamily]) -> (Double, [Outfit.Reason]) {
        let accents = Array(Set(colors.filter { !$0.isNeutral && $0 != .multicolor }))
            .sorted { $0.rawValue < $1.rawValue }
        let patterned = colors.filter { $0 == .multicolor }.count
        if patterned > 1 { return (0.2, []) }
        switch accents.count {
        case 0:
            return (patterned == 1 ? 0.85 : 0.9, [.neutralBase])
        case 1:
            return (patterned == 1 ? 0.6 : 1.0, [.neutralBase])
        case 2:
            guard let a = accents[0].hue, let b = accents[1].hue else { return (0.5, []) }
            var d = abs(a - b).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            if d <= 45 || d >= 150 { return (0.8, [.harmoniousColors(accents[0], accents[1])]) }
            return (0.3, [])
        default:
            return (0.15, [])
        }
    }
}
