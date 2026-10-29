import Foundation

/// The user's colouring and build, from which cuts, garments and colours are suggested.
///
/// Colour: the four-season system used by colour consultants. The skin's undertone
/// (warm golden / cool pink-blue / neutral) and depth (light to deep) give spring
/// (warm, light), summer (cool, light), autumn (warm, deep) or winter (cool, deep);
/// a neutral undertone follows the depth.
///
/// Build: the usual stylist body shapes from girth ratios. Women (bust, waist, hips):
/// hourglass, pear, apple, inverted triangle, rectangle. Men (chest or shoulders,
/// waist, hips): inverted triangle, rectangle, triangle, oval.
public struct StyleProfile: Codable, Hashable, Sendable {
    public enum Undertone: String, Codable, CaseIterable, Sendable { case warm, cool, neutral }
    public enum SkinDepth: String, Codable, CaseIterable, Sendable { case light, medium, tan, deep }
    public enum Vibe: String, Codable, CaseIterable, Sendable { case classic, casual, minimal, bold }

    public var undertone: Undertone
    public var depth: SkinDepth
    public var vibe: Vibe

    public init(undertone: Undertone, depth: SkinDepth, vibe: Vibe) {
        self.undertone = undertone
        self.depth = depth
        self.vibe = vibe
    }

    public enum ColorSeason: String, Codable, Sendable { case spring, summer, autumn, winter }

    public var colorSeason: ColorSeason {
        let light = depth == .light || depth == .medium
        switch undertone {
        case .warm: return light ? .spring : .autumn
        case .cool: return light ? .summer : .winter
        case .neutral: return light ? .summer : .autumn
        }
    }

    /// Colours (in wardrobe colour families) that flatter, and ones to keep away from the face.
    public var palette: (flattering: [ColorFamily], avoid: [ColorFamily]) {
        switch colorSeason {
        case .spring: ([.beige, .orange, .yellow, .green, .blue, .pink, .brown], [.black, .gray, .burgundy])
        case .summer: ([.navy, .gray, .blue, .pink, .purple, .white, .denim], [.orange, .yellow, .brown])
        case .autumn: ([.olive, .brown, .beige, .orange, .burgundy, .green, .denim], [.pink, .purple, .gray])
        case .winter: ([.black, .white, .navy, .red, .burgundy, .purple, .blue], [.beige, .orange, .olive])
        }
    }
}

public enum BodyShape: String, Codable, Sendable {
    // Shared
    case invertedTriangle, rectangle
    // Women
    case hourglass, pear, apple
    // Men
    case triangle, oval

    /// - Parameters:
    ///   - female: women's or men's shape set.
    ///   - chest: bust or chest girth; `shoulder` is the shoulder width (men's shapes use it).
    public static func classify(chest: Double, waist: Double, hip: Double, shoulder: Double?, female: Bool) -> BodyShape {
        if female {
            // Common stylist rules on bust/waist/hip girths.
            if waist >= chest * 0.95, waist >= hip * 0.9 { return .apple }
            if abs(chest - hip) <= 5, waist <= min(chest, hip) * 0.78 { return .hourglass }
            if hip - chest > 5 { return .pear }
            if chest - hip > 5 { return .invertedTriangle }
            return .rectangle
        }
        if waist >= chest * 0.98 { return .oval }
        if hip > chest * 1.03 { return .triangle }
        // A broad chest or shoulders over a narrow waist.
        let shoulderRatio = shoulder.map { $0 * 2.4 / waist } ?? 0
        if chest - waist >= 18 || shoulderRatio >= 1.25 { return .invertedTriangle }
        return .rectangle
    }
}
