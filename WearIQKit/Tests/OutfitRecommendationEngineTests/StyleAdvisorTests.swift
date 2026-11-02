import Testing
@testable import OutfitRecommendationEngine

@Suite struct StyleAdvisorTests {
    /// Typical skin colours (sRGB) land where dermatology puts them.
    @Test func skinTones() {
        let fair = SkinToneAnalyzer.classify(red: 0.93, green: 0.80, blue: 0.72)
        #expect(fair.depth == .light)
        let olive = SkinToneAnalyzer.classify(red: 0.78, green: 0.60, blue: 0.43)
        #expect([.medium, .tan].contains(olive.depth))
        #expect(olive.undertone == .warm)
        let deep = SkinToneAnalyzer.classify(red: 0.36, green: 0.23, blue: 0.17)
        #expect(deep.depth == .deep)
        let rosy = SkinToneAnalyzer.classify(red: 0.92, green: 0.74, blue: 0.72)
        #expect(rosy.undertone == .cool)
    }

    @Test func styleForShape() {
        let a = StyleAdvice.make(shape: .apple, vibe: .bold, occasion: .everyday, ease: .relaxed)
        #expect(!a.suitsChosen)
        #expect(a.bestVibes.first == .minimal)
        #expect(a.cuts.contains(.vNeck))
        let w = StyleAdvice.make(shape: .rectangle, vibe: .casual, occasion: .work, ease: .fitted)
        #expect(w.bestVibes.prefix(2).contains(.classic))
        #expect(w.fabrics.contains(.workFabrics))
    }
}
