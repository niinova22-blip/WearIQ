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

    @Test func bodySectionsKeepTheMeasuredGirths() {
        let a = Avatar(me)
        // The waist level of the loft: the ring of vertices closest to 0.601 of stature.
        let n = Shapes.segments
        let rings = stride(from: 0, to: a.body.positions.count - n, by: n).map { Array(a.body.positions[$0..<($0 + n)]) }
        let waist = rings.min { abs($0[0].y - 0.601 * 1.73) < abs($1[0].y - 0.601 * 1.73) }!
        let perimeter = zip(waist, waist.dropFirst() + [waist[0]]).reduce(Float(0)) { $0 + ($1.0 - $1.1).length }
        #expect(abs(perimeter * 100 - 83.5) < 1.0)
    }

    @Test func tightWovenStrainsAndStretchGives() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = -5; fit.waistEase = -4; fit.hipEase = -2
        fit.fabric = .woven
        let woven = Avatar(me, garment: fit).garment!.maxStrain
        fit.fabric = Fabric(fibres: ["cotton": 95, "elastane": 5], knit: true)
        let stretchy = Avatar(me, garment: fit).garment!.maxStrain
        fit.chestEase = 14; fit.waistEase = 14; fit.hipEase = 14
        fit.fabric = .woven
        let loose = Avatar(me, garment: fit).garment!
        #expect(woven > 1)
        #expect(stretchy < woven / 3)
        // Loose fabric hangs nearly relaxed (gravity, its own weight, stretches it slightly).
        let relaxed = loose.strain.filter { $0 < 0.5 }.count
        #expect(Float(relaxed) / Float(loose.strain.count) > 0.9)
        #expect(loose.strain.count == loose.positions.count)
    }

    @Test func garmentStaysOutsideTheBody() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = -6
        let avatar = Avatar(me, garment: fit)
        // At chest height, every garment vertex on the torso sits at least as far out as
        // the body section there.
        let chestY: Float = 0.728 * 1.73
        let body = avatar.body.positions.filter { abs($0.y - chestY) < 0.01 && abs($0.x) < 0.15 }
        let garment = avatar.garment!.positions.filter { abs($0.y - chestY) < 0.01 && abs($0.x) < 0.15 }
        let bodyFront = body.map(\.z).max()!, garmentFront = garment.map(\.z).max()!
        #expect(garmentFront >= bodyFront)
    }

    @Test func fabricFromComposition() {
        let jersey = Fabric(fibres: ["cotton": 95, "elastane": 5], knit: true)
        let denim = Fabric(fibres: ["cotton": 100], knit: false)
        let viscose = Fabric(fibres: ["viscose": 100], knit: false)
        #expect(jersey.stretchLimit > 0.3)
        #expect(denim.stretchLimit < 0.05)
        #expect(viscose.drape < denim.drape)
        // Fluid fabrics fall into more folds (Cusick).
        #expect(viscose.folds > denim.folds)
    }
}
