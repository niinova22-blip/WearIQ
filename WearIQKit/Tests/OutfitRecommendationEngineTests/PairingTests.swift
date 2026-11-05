import Testing
@testable import OutfitRecommendationEngine

@Suite struct PairingTests {
    @Test func whiteOversizedShirtGetsABlackMiniSkirt() {
        let s = Pairing.suggest(for: .init(kind: .top, color: .white, fit: .roomy), female: true)
        #expect(s.first == .init(piece: .miniSkirt, color: .black))
    }

    @Test func fittedTopBalancesWithVolume() {
        let s = Pairing.suggest(for: .init(kind: .top, color: .black, fit: .close), female: false)
        #expect(s.first?.piece == .straightTrousers || s.first?.piece == .wideTrousers)
        #expect(s.first?.color == .white)
    }

    @Test func wideTrousersGetAFittedTop() {
        let s = Pairing.suggest(for: .init(kind: .bottom, color: .beige, fit: .roomy), female: true)
        let first = s.first!.piece
        #expect(first == .croppedTop || first == .fittedTop)
    }

    @Test func colouredPieceGetsNeutralsThenItsComplement() {
        let colors = Pairing.partners(for: .red, favourite: nil)
        let neutral = colors.prefix(3).allSatisfy { $0.isNeutral }
        #expect(neutral)
        #expect(colors.contains(.green))
    }

    @Test func favouriteColourIsOffered() {
        #expect(Pairing.partners(for: .white, favourite: .pink)[1] == .pink)
    }

    @Test(arguments: [("Kadın Beyaz Oversize Gömlek", ColorFamily.white), ("Lacivert Slim Fit Jean", .navy),
                      ("Women's Black Mini Skirt", .black), ("Ekru Triko Kazak", .beige), ("Basic Tişört", nil)])
    func colourFromName(name: String, expected: ColorFamily?) {
        #expect(ColorFamily.named(in: name) == expected)
    }
}

/// Colours read from the camera, named the way a person would.
@Suite struct ColorNamingTests {
    @Test func darkColoursKeepTheirHue() {
        // A tester's khaki trousers indoors were called black.
        #expect(ColorFamily.nearest(red: 0.20, green: 0.21, blue: 0.15) == .olive)
        #expect(ColorFamily.nearest(red: 0.10, green: 0.22, blue: 0.13) == .green)
        #expect(ColorFamily.nearest(red: 0.25, green: 0.17, blue: 0.12) == .brown)
        #expect(ColorFamily.nearest(red: 0.08, green: 0.10, blue: 0.20) == .navy)
        #expect(ColorFamily.nearest(red: 0.28, green: 0.06, blue: 0.09) == .burgundy)
    }

    @Test func neutralsByLightness() {
        #expect(ColorFamily.nearest(red: 0.05, green: 0.05, blue: 0.06) == .black)
        // Black under warm indoor light is still black.
        #expect(ColorFamily.nearest(red: 0.10, green: 0.08, blue: 0.06) == .black)
        #expect(ColorFamily.nearest(red: 0.30, green: 0.30, blue: 0.31) == .gray)
        #expect(ColorFamily.nearest(red: 0.60, green: 0.60, blue: 0.60) == .gray)
        #expect(ColorFamily.nearest(red: 0.93, green: 0.93, blue: 0.92) == .white)
    }

    @Test func coloursByName() {
        #expect(ColorFamily.nearest(red: 0.84, green: 0.76, blue: 0.62) == .beige)
        #expect(ColorFamily.nearest(red: 0.30, green: 0.42, blue: 0.60) == .denim)
        #expect(ColorFamily.nearest(red: 0.15, green: 0.35, blue: 0.80) == .blue)
        #expect(ColorFamily.nearest(red: 0.80, green: 0.12, blue: 0.12) == .red)
        #expect(ColorFamily.nearest(red: 0.95, green: 0.60, blue: 0.72) == .pink)
        #expect(ColorFamily.nearest(red: 0.95, green: 0.50, blue: 0.15) == .orange)
        #expect(ColorFamily.nearest(red: 0.50, green: 0.25, blue: 0.60) == .purple)
    }
}
