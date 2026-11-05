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
