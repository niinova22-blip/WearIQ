import Testing
@testable import AvatarEngine

@Suite struct AvatarTests {
    // The device scan: 173 cm man.
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)

    @Test func bodyHasTheUsersHeight() {
        let avatar = Avatar(me)
        #expect(abs(avatar.body.maxY - 1.73) < 0.03)
        #expect(avatar.body.minY >= 0 && avatar.body.minY < 0.01)
        #expect(avatar.body.normals.count == avatar.body.positions.count)
        #expect(avatar.body.indices.count % 3 == 0)
    }

    @Test func waistGirthMatches() {
        let (a, b) = Shapes.ellipse(girthCm: 83.5, depthRatio: 0.75)
        // Ramanujan's perimeter of the resulting ellipse gives back the girth.
        let A = Double(a), B = Double(b), hh = (A - B) * (A - B) / ((A + B) * (A + B))
        let perimeter = Double.pi * (A + B) * (1 + 3 * hh / (10 + (4 - 3 * hh).squareRoot())) * 100
        #expect(abs(perimeter - 83.5) < 0.1)
    }

    @Test func longTrousersStackOnTheShoe() {
        var fit = Avatar.GarmentFit(kind: .trousers)
        fit.lengthDelta = 6
        let long = Avatar(me, garment: fit)
        fit.lengthDelta = 0
        let exact = Avatar(me, garment: fit)
        fit.lengthDelta = -4
        let short = Avatar(me, garment: fit)
        // Longer reaches the floor and gains fold rings; shorter stops above the ankle.
        #expect(long.garment!.minY < exact.garment!.minY)
        #expect(long.garment!.positions.count > exact.garment!.positions.count)
        #expect(short.anchors[.hem]!.y > exact.anchors[.hem]!.y + 0.035)
    }

    @Test func longSleevesCoverTheHand() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: true))
        fit.sleeveDelta = 5
        let long = Avatar(me, garment: fit)
        fit.sleeveDelta = 0
        let exact = Avatar(me, garment: fit)
        #expect(long.anchors[.sleeveEnd]!.y < exact.anchors[.sleeveEnd]!.y - 0.03)
    }

    @Test func droppedShoulderMovesTheSeam() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        let regular = Avatar(me, garment: fit)
        fit.shoulderDelta = 8
        fit.chestEase = 30
        let oversized = Avatar(me, garment: fit)
        #expect(oversized.anchors[.shoulder]!.x > regular.anchors[.shoulder]!.x + 0.03)
        #expect(oversized.anchors[.chest]!.x > regular.anchors[.chest]!.x)
    }
}
