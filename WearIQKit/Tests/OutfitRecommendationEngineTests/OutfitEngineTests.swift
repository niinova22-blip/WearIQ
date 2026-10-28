import Testing
@testable import OutfitRecommendationEngine

private let shirt = WardrobeItem(name: "White oxford", category: .top, color: .white, styles: [.business, .smartCasual])
private let tee = WardrobeItem(name: "Red tee", category: .top, color: .red, seasons: [.spring, .summer], styles: [.casual])
private let chinos = WardrobeItem(name: "Navy chinos", category: .bottom, color: .navy, styles: [.business, .smartCasual, .casual])
private let joggers = WardrobeItem(name: "Grey joggers", category: .bottom, color: .gray, styles: [.sporty])
private let pinkShorts = WardrobeItem(name: "Pink shorts", category: .bottom, color: .pink, seasons: [.summer], styles: [.casual])
private let greenPants = WardrobeItem(name: "Green pants", category: .bottom, color: .green, styles: [.casual])
private let blazer = WardrobeItem(name: "Navy blazer", category: .outerwear, color: .navy, styles: [.business, .formal])
private let coat = WardrobeItem(name: "Camel coat", category: .outerwear, color: .beige, seasons: [.autumn, .winter], styles: [.business, .smartCasual, .casual])
private let loafers = WardrobeItem(name: "Brown loafers", category: .shoes, color: .brown, styles: [.business, .smartCasual])
private let runners = WardrobeItem(name: "Runners", category: .shoes, color: .white, styles: [.sporty, .casual])
private let dress = WardrobeItem(name: "Black dress", category: .dress, color: .black, styles: [.evening, .formal])

private let wardrobe = [shirt, tee, chinos, joggers, pinkShorts, greenPants, blazer, coat, loafers, runners, dress]

@Suite struct OutfitEngineTests {
    let engine = RuleBasedOutfitEngine()

    @Test func workOutfitUsesBusinessPieces() throws {
        let outfits = engine.outfits(from: wardrobe, occasion: .work, season: .spring, preferences: .init())
        let best = try #require(outfits.first)
        #expect(best.items.contains(shirt))
        #expect(best.items.contains(chinos))
        #expect(best.items.contains(loafers))
        #expect(!best.items.contains(joggers)) // sporty pieces don't suit work
    }

    @Test func sportOutfitOnlyUsesSuitableItems() {
        let outfits = engine.outfits(from: wardrobe, occasion: .sport, season: .summer, preferences: .init())
        #expect(!outfits.isEmpty)
        for o in outfits {
            #expect(o.items.allSatisfy { engine.styleScore($0, .sport) > 0 })
        }
    }

    @Test func respectsSeason() {
        let winter = engine.outfits(from: wardrobe, occasion: .daily, season: .winter, preferences: .init(), limit: 20)
        #expect(winter.allSatisfy { !$0.items.contains(tee) && !$0.items.contains(pinkShorts) })
        // Cold weather: outerwear is added when the wardrobe has some.
        #expect(winter.allSatisfy { $0.items.contains { $0.category == .outerwear } })
    }

    @Test func eveningCanUseDress() {
        let outfits = engine.outfits(from: wardrobe, occasion: .evening, season: .spring, preferences: .init())
        #expect(outfits.contains { $0.items.contains(dress) })
    }

    @Test func avoidedColorsAreExcluded() {
        let outfits = engine.outfits(from: wardrobe, occasion: .daily, season: .summer,
                                     preferences: .init(avoidedColors: [.red]), limit: 20)
        #expect(outfits.allSatisfy { !$0.items.contains(tee) })
    }

    @Test func clashingAccentsScoreLowerThanNeutralBase() {
        let neutral = engine.evaluate([shirt, chinos], occasion: .daily, preferences: .init(), layered: false)
        let clash = engine.evaluate([tee, pinkShorts], occasion: .daily, preferences: .init(), layered: false)
        #expect(neutral.score > clash.score)
    }

    @Test func colorHarmonyRules() {
        #expect(RuleBasedOutfitEngine.colorHarmony([.white, .navy]).0 == 0.9)
        #expect(RuleBasedOutfitEngine.colorHarmony([.red, .navy]).0 == 1.0)
        #expect(RuleBasedOutfitEngine.colorHarmony([.red, .green]).0 == 0.8)   // complementary
        #expect(RuleBasedOutfitEngine.colorHarmony([.red, .pink]).0 == 0.8)    // analogous (30°)
        #expect(RuleBasedOutfitEngine.colorHarmony([.blue, .orange]).0 == 0.8) // complementary
        #expect(RuleBasedOutfitEngine.colorHarmony([.blue, .yellow]).0 == 0.3)
        #expect(RuleBasedOutfitEngine.colorHarmony([.green, .purple]).0 == 0.3)
        #expect(RuleBasedOutfitEngine.colorHarmony([.red, .green, .blue]).0 == 0.15)
    }

    @Test func goodFitRanksHigher() {
        var wellFitting = chinos
        wellFitting.fitScore = 1
        var poorlyFitting = chinos
        poorlyFitting.fitScore = 0.2
        let a = engine.evaluate([shirt, wellFitting], occasion: .work, preferences: .init(), layered: false)
        let b = engine.evaluate([shirt, poorlyFitting], occasion: .work, preferences: .init(), layered: false)
        #expect(a.score > b.score)
        #expect(a.reasons.contains(.goodFit))
    }

    @Test func distinctBasesAndDeterministic() {
        let a = engine.outfits(from: wardrobe, occasion: .daily, season: .spring, preferences: .init(), limit: 10)
        let b = engine.outfits(from: wardrobe, occasion: .daily, season: .spring, preferences: .init(), limit: 10)
        #expect(a == b)
        let bases = a.map { $0.items.filter { [.top, .bottom, .dress].contains($0.category) }.map(\.id) }
        #expect(Set(bases).count == bases.count)
    }

    @Test func emptyWardrobe() {
        #expect(engine.outfits(from: [], occasion: .daily, season: .summer, preferences: .init()).isEmpty)
    }
}
