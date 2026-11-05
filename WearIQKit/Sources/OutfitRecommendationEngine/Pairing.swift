import Foundation

/// What goes with a garment the user checked: the stylist's rules of balance and colour,
/// as codes the app words. "A white oversized shirt → a black mini skirt or slim dark
/// jeans."
///
/// - Volume: one roomy piece, one close one (a loose top over a slim or short bottom; a
///   fitted top over wide trousers or a full skirt), so the outline keeps a waist.
/// - Colour: a neutral piece with a neutral that contrasts it (white with black, navy or
///   denim; black with white, beige or grey), or with the user's favourite colour; a
///   coloured piece with neutrals, or its complementary for a bolder look.
/// - A dress with a layer: a denim jacket or a blazer.
public enum Pairing {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case top, bottom, dress, outerwear
    }

    public enum Fit: String, Codable, Sendable {
        case close, regular, roomy
    }

    /// A checked garment, as far as pairing goes.
    public struct Item: Sendable, Equatable {
        public var kind: Kind
        public var color: ColorFamily?
        public var fit: Fit
        public init(kind: Kind, color: ColorFamily?, fit: Fit) {
            self.kind = kind; self.color = color; self.fit = fit
        }
    }

    /// A piece to wear with it.
    public enum Piece: String, Codable, Sendable {
        case miniSkirt, midiSkirt, slimJeans, straightTrousers, wideTrousers, tailoredTrousers, shorts
        case fittedTop, croppedTop, relaxedShirt, knitTop, tee
        case denimJacket, blazer, trenchCoat
    }

    public struct Suggestion: Sendable, Equatable {
        public var piece: Piece
        public var color: ColorFamily
    }

    public static func suggest(for item: Item, female: Bool, favourite: ColorFamily? = nil) -> [Suggestion] {
        let colors = partners(for: item.color, favourite: favourite)
        let pieces: [Piece]
        switch (item.kind, item.fit) {
        case (.top, .roomy):
            pieces = female ? [.miniSkirt, .slimJeans, .shorts] : [.slimJeans, .straightTrousers, .shorts]
        case (.top, .close):
            pieces = female ? [.wideTrousers, .midiSkirt, .straightTrousers] : [.straightTrousers, .wideTrousers]
        case (.top, .regular):
            pieces = female ? [.straightTrousers, .midiSkirt, .slimJeans] : [.straightTrousers, .tailoredTrousers, .slimJeans]
        case (.bottom, .roomy):
            pieces = female ? [.croppedTop, .fittedTop, .knitTop] : [.fittedTop, .tee, .knitTop]
        case (.bottom, .close):
            pieces = female ? [.relaxedShirt, .knitTop, .blazer] : [.relaxedShirt, .knitTop, .denimJacket]
        case (.bottom, .regular):
            pieces = [.tee, .relaxedShirt, .knitTop]
        case (.dress, _):
            pieces = [.denimJacket, .blazer, .trenchCoat]
        case (.outerwear, _):
            pieces = female ? [.slimJeans, .midiSkirt, .knitTop] : [.slimJeans, .knitTop, .tee]
        }
        return pieces.enumerated().map { i, piece in Suggestion(piece: piece, color: colors[i % colors.count]) }
    }

    /// Colours that go with this one, best first.
    static func partners(for color: ColorFamily?, favourite: ColorFamily?) -> [ColorFamily] {
        var out: [ColorFamily]
        switch color {
        case .white?: out = [.black, .navy, .denim]
        case .black?: out = [.white, .beige, .gray]
        case .gray?: out = [.black, .white, .navy]
        case .navy?: out = [.white, .beige, .gray]
        case .beige?: out = [.white, .navy, .brown]
        case .brown?: out = [.beige, .white, .denim]
        case .denim?: out = [.white, .black, .beige]
        case .olive?: out = [.beige, .white, .black]
        case let c? where c.hue != nil:
            // A colour with neutrals, then its complementary for a bolder look.
            out = [.white, .black, .denim]
            if let h = c.hue, let complement = ColorFamily.allCases.first(where: { $0.hue.map { abs(($0 - h + 360).truncatingRemainder(dividingBy: 360) - 180) < 20 } ?? false }) {
                out.append(complement)
            }
        default: out = [.black, .white, .denim]
        }
        if let favourite, favourite != color, !out.contains(favourite) { out.insert(favourite, at: 1) }
        return out
    }
}

extension ColorFamily {
    /// The colour a product's name says (Turkish or English), if one does.
    public static func named(in text: String) -> ColorFamily? {
        let t = text.lowercased(with: Locale(identifier: "tr_TR"))
        let words: [(String, ColorFamily)] = [
            ("lacivert", .navy), ("navy", .navy), ("siyah", .black), ("black", .black), ("beyaz", .white), ("white", .white),
            ("ekru", .beige), ("krem", .beige), ("bej", .beige), ("beige", .beige), ("cream", .beige), ("camel", .beige),
            ("gri", .gray), ("grey", .gray), ("gray", .gray), ("antrasit", .gray), ("kahverengi", .brown), ("kahve", .brown),
            ("brown", .brown), ("denim", .denim), ("indigo", .denim), ("haki", .olive), ("khaki", .olive), ("olive", .olive),
            ("bordo", .burgundy), ("burgundy", .burgundy), ("kırmızı", .red), ("red", .red), ("pembe", .pink), ("pink", .pink),
            ("turuncu", .orange), ("orange", .orange), ("sarı", .yellow), ("yellow", .yellow), ("mor", .purple),
            ("lila", .purple), ("purple", .purple), ("yeşil", .green), ("green", .green), ("mavi", .blue), ("blue", .blue),
        ]
        let tokens = Set(t.split { !$0.isLetter }.map(String.init))
        return words.first { tokens.contains($0.0) }?.1
    }
}
