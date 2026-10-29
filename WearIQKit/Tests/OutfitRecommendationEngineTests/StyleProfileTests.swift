import Testing
@testable import OutfitRecommendationEngine

@Suite struct StyleProfileTests {
    @Test func seasons() {
        #expect(StyleProfile(undertone: .warm, depth: .light, vibe: .casual).colorSeason == .spring)
        #expect(StyleProfile(undertone: .cool, depth: .light, vibe: .casual).colorSeason == .summer)
        #expect(StyleProfile(undertone: .warm, depth: .deep, vibe: .casual).colorSeason == .autumn)
        #expect(StyleProfile(undertone: .cool, depth: .tan, vibe: .casual).colorSeason == .winter)
    }

    @Test func palettesDontOverlap() {
        for u in StyleProfile.Undertone.allCases {
            for d in StyleProfile.SkinDepth.allCases {
                let p = StyleProfile(undertone: u, depth: d, vibe: .classic).palette
                #expect(Set(p.flattering).isDisjoint(with: p.avoid))
            }
        }
    }

    @Test func mensShapes() {
        // The device scan: chest 90, waist 83.5, hips 89, shoulders 37.6.
        #expect(BodyShape.classify(chest: 90, waist: 83.5, hip: 89, shoulder: 37.6, female: false) == .rectangle)
        #expect(BodyShape.classify(chest: 108, waist: 84, hip: 98, shoulder: 47, female: false) == .invertedTriangle)
        #expect(BodyShape.classify(chest: 100, waist: 104, hip: 104, shoulder: 42, female: false) == .oval)
        #expect(BodyShape.classify(chest: 92, waist: 86, hip: 100, shoulder: 38, female: false) == .triangle)
    }

    @Test func womensShapes() {
        #expect(BodyShape.classify(chest: 92, waist: 68, hip: 94, shoulder: nil, female: true) == .hourglass)
        #expect(BodyShape.classify(chest: 86, waist: 72, hip: 102, shoulder: nil, female: true) == .pear)
        #expect(BodyShape.classify(chest: 100, waist: 96, hip: 100, shoulder: nil, female: true) == .apple)
        #expect(BodyShape.classify(chest: 98, waist: 80, hip: 90, shoulder: nil, female: true) == .invertedTriangle)
        #expect(BodyShape.classify(chest: 88, waist: 76, hip: 90, shoulder: nil, female: true) == .rectangle)
    }
}
