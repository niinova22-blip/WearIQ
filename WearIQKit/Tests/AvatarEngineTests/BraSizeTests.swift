import Foundation
import Testing
@testable import AvatarEngine
import WearIQCore

@Suite struct BraSizeTests {
    @Test(arguments: [("75B", 75.0, 15.0), ("80 dd", 80.0, 21.0), ("34C", 77.36, 18.5), ("70", 70.0, nil)])
    func parses(text: String, underbust: Double, cup: Double?) throws {
        let size = try #require(BraSize(text))
        #expect(abs(size.underbustCm - underbust) < 0.01)
        if let cup { #expect(abs((size.cupCm ?? 0) - cup) < 0.01) } else { #expect(size.cupCm == nil) }
    }

    @Test(arguments: ["", "B", "75Z", "150C", "12A"])
    func rejects(text: String) {
        #expect(BraSize(text) == nil)
    }

    /// The same chest with a smaller band is a fuller bust on the avatar, and the chest
    /// girth itself stays where it was measured.
    @Test func bandShapesTheBust() throws {
        let model = try #require(SomaModel.shared)
        var m = Avatar.Measurements(height: 165, chest: 96, waist: 76, hip: 100, thigh: 58,
                                    shoulderWidth: 36, armLength: 54, inseam: 76, sex: .female)
        m.underbust = 82
        let small = model.body(for: m.somaTarget, bust: m.bust)
        m.underbust = 72
        let full = model.body(for: m.somaTarget, bust: m.bust)
        #expect(model.bust(full) > model.bust(small) + 3)
        #expect(abs(model.measure(full)[1] - 96) < 0.5)
        #expect(abs(model.measure(small)[1] - 96) < 0.5)
    }
}
