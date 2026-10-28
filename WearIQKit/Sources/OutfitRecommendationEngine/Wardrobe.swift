import Foundation

public enum WardrobeCategory: String, Codable, CaseIterable, Sendable {
    case top, bottom, dress, outerwear, shoes, accessory
}

public enum ColorFamily: String, Codable, CaseIterable, Sendable {
    case black, white, gray, navy, beige, brown, denim
    case blue, green, olive, red, burgundy, pink, orange, yellow, purple, multicolor

    /// Neutrals pair with anything.
    public var isNeutral: Bool {
        switch self {
        case .black, .white, .gray, .navy, .beige, .brown, .denim, .olive: true
        default: false
        }
    }

    /// Position on the artists' RYB colour wheel (degrees), which is what fashion colour
    /// rules are based on: red–green, blue–orange and yellow–purple are complementary.
    var hue: Double? {
        switch self {
        case .red: 0
        case .burgundy: 350
        case .pink: 330
        case .orange: 60
        case .yellow: 120
        case .green: 180
        case .blue: 240
        case .purple: 300
        default: nil
        }
    }
}

public enum Season: String, Codable, CaseIterable, Sendable {
    case spring, summer, autumn, winter
}

public enum StyleTag: String, Codable, CaseIterable, Sendable {
    case casual, smartCasual, business, formal, sporty, evening
}

public enum Occasion: String, Codable, CaseIterable, Sendable {
    case daily, work, formal, sport, evening, specialEvent

    /// How well each style suits the occasion (0–1). Missing = unsuitable.
    var styleFit: [StyleTag: Double] {
        switch self {
        case .daily: [.casual: 1, .smartCasual: 0.9, .sporty: 0.6, .business: 0.4]
        case .work: [.business: 1, .smartCasual: 0.9, .formal: 0.7, .casual: 0.3]
        case .formal: [.formal: 1, .business: 0.7, .evening: 0.6]
        case .sport: [.sporty: 1, .casual: 0.3]
        case .evening: [.evening: 1, .smartCasual: 0.8, .formal: 0.7, .casual: 0.3]
        case .specialEvent: [.formal: 1, .evening: 0.9, .business: 0.6, .smartCasual: 0.5]
        }
    }

    /// Styles that clearly suit the occasion (for suggesting pieces to add).
    public var suitedStyles: Set<StyleTag> { Set(styleFit.filter { $0.value >= 0.8 }.keys) }
}

public struct WardrobeItem: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: WardrobeCategory
    public var color: ColorFamily
    public var seasons: Set<Season>
    public var styles: Set<StyleTag>
    /// 0–1 from a fit analysis of this item, if one exists. Poorly fitting items rank lower.
    public var fitScore: Double?

    public init(id: UUID = UUID(), name: String, category: WardrobeCategory, color: ColorFamily,
                seasons: Set<Season> = Set(Season.allCases), styles: Set<StyleTag>, fitScore: Double? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.color = color
        self.seasons = seasons
        self.styles = styles
        self.fitScore = fitScore
    }
}

public struct OutfitPreferences: Codable, Hashable, Sendable {
    public var favoriteColors: Set<ColorFamily>
    public var avoidedColors: Set<ColorFamily>

    public init(favoriteColors: Set<ColorFamily> = [], avoidedColors: Set<ColorFamily> = []) {
        self.favoriteColors = favoriteColors
        self.avoidedColors = avoidedColors
    }
}
