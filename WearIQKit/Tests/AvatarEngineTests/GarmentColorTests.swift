import Testing
@testable import AvatarEngine

@Suite struct GarmentColorTests {
    typealias C = GarmentColor.RGB

    /// A navy shirt with shading and a bit of skin at the neckline.
    @Test func solidColourThroughShading() throws {
        var pixels: [C] = []
        for i in 0..<900 {
            let shade = 0.8 + Double(i % 10) * 0.04
            pixels.append(C(0.12 * shade, 0.16 * shade, 0.35 * shade))
        }
        pixels += Array(repeating: C(0.85, 0.65, 0.52), count: 100)
        let result = try #require(GarmentColor.dominant(pixels))
        #expect(result.color.b > result.color.r + 0.1)
        #expect(!result.patterned)
    }

    @Test func skinIsNotTheGarment() throws {
        // A low neckline: skin is the biggest cluster, a red top the second.
        let pixels = Array(repeating: C(0.86, 0.66, 0.54), count: 550) + Array(repeating: C(0.8, 0.1, 0.12), count: 450)
        let result = try #require(GarmentColor.dominant(pixels))
        #expect(result.color.r > 0.7 && result.color.g < 0.2)
    }

    @Test func stripesArePatterned() throws {
        let pixels = (0..<1000).map { $0 % 2 == 0 ? C(0.95, 0.95, 0.95) : C(0.1, 0.15, 0.4) }
        #expect(try #require(GarmentColor.dominant(pixels)).patterned)
    }

    @Test func tooFewPixels() {
        #expect(GarmentColor.dominant([C(1, 0, 0)]) == nil)
    }
}
