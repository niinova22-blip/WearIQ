import Foundation
import Testing
@testable import AvatarEngine
import WearIQCore

@Suite struct AvatarTests {
    // The device scan: 173 cm man.
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)
    let quick = Avatar.Detail.preview

    @Test func bodyHasTheUsersHeight() {
        let avatar = Avatar(me, detail: quick)
        #expect(abs(avatar.body.maxY - 1.73) < 0.03)
        #expect(avatar.body.minY >= -0.005 && avatar.body.minY < 0.015)
        #expect(avatar.body.normals.count == avatar.body.positions.count)
        #expect(avatar.body.indices.count % 3 == 0)
    }

    @Test func facesPointOutward() {
        let mesh = Avatar(me, detail: quick).body
        var agree = 0, total = 0
        for t in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = mesh.positions[Int(mesh.indices[t])], b = mesh.positions[Int(mesh.indices[t + 1])]
            let c = mesh.positions[Int(mesh.indices[t + 2])]
            let face = (b - a).cross(c - a)
            guard face.length > 1e-9 else { continue }
            total += 1
            if face.dot(mesh.normals[Int(mesh.indices[t])]) > 0 { agree += 1 }
        }
        #expect(Double(agree) / Double(total) > 0.97)
    }

    @Test func waistGirthMatches() {
        let (a, b) = Shapes.ellipse(girthCm: 83.5, depthRatio: 0.75)
        // Ramanujan's perimeter of the resulting ellipse gives back the girth.
        let A = Double(a), B = Double(b), hh = (A - B) * (A - B) / ((A + B) * (A + B))
        let perimeter = Double.pi * (A + B) * (1 + 3 * hh / (10 + (4 - 3 * hh).squareRoot())) * 100
        #expect(abs(perimeter - 83.5) < 0.1)
    }

    @Test func bodyKeepsTheMeasuredGirths() {
        let model = BodyModel.make(me)
        // Walk out from the middle in 96 directions to the skin and add up the outline.
        func girth(_ y: Float) -> Float {
            let center = model.torso.ring(at: y).center
            let points = (0..<96).map { k -> Vec3 in
                let t = Float(k) / 96 * 2 * .pi
                var r: Float = 0
                while model.distance(Vec3(center.x + r * cos(t), y, center.z + r * sin(t))) < 0 { r += 0.0005 }
                return Vec3(center.x + r * cos(t), y, center.z + r * sin(t))
            }
            return zip(points, points.dropFirst() + [points[0]]).reduce(Float(0)) { $0 + ($1.0 - $1.1).length }
        }
        #expect(abs(girth(model.waistY) * 100 - 83.5) < 1.5)
        #expect(abs(girth(model.hipY) * 100 - 89) < 2)
    }

    @Test func longTrousersReachTheFloor() {
        var fit = Avatar.GarmentFit(kind: .trousers)
        fit.lengthDelta = 6
        let long = Avatar(me, garment: fit, detail: quick)
        fit.lengthDelta = 0
        let exact = Avatar(me, garment: fit, detail: quick)
        fit.lengthDelta = -4
        let short = Avatar(me, garment: fit, detail: quick)
        #expect(long.garment!.minY < exact.garment!.minY - 0.02)
        #expect(short.garment!.minY > exact.garment!.minY + 0.03)
        #expect(!exact.seams.isEmpty && exact.seams.count % 2 == 0)
    }

    @Test func longSleevesCoverTheHand() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: true))
        fit.sleeveDelta = 5
        let long = Avatar(me, garment: fit, detail: quick)
        fit.sleeveDelta = 0
        let exact = Avatar(me, garment: fit, detail: quick)
        #expect(long.anchors[.sleeveEnd]!.y < exact.anchors[.sleeveEnd]!.y - 0.03)
        #expect(long.garment!.minY <= exact.garment!.minY + 0.001)
    }

    @Test func droppedShoulderMovesTheSeam() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        let regular = Avatar(me, garment: fit, detail: quick)
        fit.shoulderDelta = 8
        fit.chestEase = 30
        let oversized = Avatar(me, garment: fit, detail: quick)
        #expect(oversized.anchors[.shoulder]!.x > regular.anchors[.shoulder]!.x + 0.03)
        // Standing further off the chest at the front, in the middle (no sleeve there).
        let model = BodyModel.make(me)
        let front = { (a: Avatar) in
            a.garment!.positions.filter { abs($0.y - model.chestY) < 0.03 && abs($0.x) < 0.05 }.map(\.z).max() ?? 0
        }
        #expect(front(oversized) > front(regular) + 0.01)
    }

    @Test func tightWovenPullsAndStretchGives() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = -5; fit.waistEase = -4; fit.hipEase = -2
        fit.fabric = .woven
        let woven = Avatar(me, garment: fit, detail: quick).garment!
        fit.fabric = Fabric(fibres: ["cotton": 95, "elastane": 5], knit: true)
        let stretchy = Avatar(me, garment: fit, detail: quick).garment!
        fit.chestEase = 16; fit.waistEase = 18; fit.hipEase = 18
        fit.fabric = .woven
        let loose = Avatar(me, garment: fit, detail: quick).garment!
        func share(_ m: Mesh, above v: Float) -> Float { Float(m.strain.filter { $0 > v }.count) / Float(m.strain.count) }
        #expect(share(woven, above: 0.95) > 0.2)
        #expect(share(stretchy, above: 0.95) < share(woven, above: 0.95) / 3)
        // Loose: hardly anything tight, and much of it hangs off the body.
        #expect(share(loose, above: 0.6) < 0.05)
        #expect(loose.strain.filter { $0 < 0.3 }.count > loose.strain.count / 4)
        #expect(loose.strain.count == loose.positions.count)
    }

    @Test func garmentStaysOutsideTheBody() {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = -6
        let avatar = Avatar(me, garment: fit, detail: quick)
        let model = BodyModel.make(me)
        let inside = avatar.garment!.positions.filter { model.distance($0) < -0.004 }
        #expect(Float(inside.count) / Float(avatar.garment!.positions.count) < 0.02)
    }

    @Test func landmarksSitOnTheSurface() {
        let avatar = Avatar(me, detail: quick)
        let model = BodyModel.make(me)
        #expect(avatar.landmarks.count == Avatar.Landmark.Kind.allCases.count)
        for l in avatar.landmarks { #expect(abs(model.distance(l.position)) < 0.006, "\(l.kind)") }
        let knee = avatar.landmarks.first { $0.kind == .knee }!
        #expect(abs(knee.position.y - 0.28 * 1.73) < 0.03)
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

@Suite struct BodyBySexAndGarmentKinds {
    let m = Avatar.Measurements(height: 168, chest: 92, waist: 74, hip: 98, thigh: 56,
                                shoulderWidth: 36, armLength: 54, inseam: 77)

    /// The same girths as a woman and as a man: her breasts stand out from the ribcage,
    /// his chest is the ribcage; the chest girth stays what was measured either way.
    @Test func aWomansBustStandsOut() throws {
        let soma = try #require(SomaModel.shared)
        func body(_ sex: BodySex) -> [Vec3] {
            var x = m; x.sex = sex
            return soma.vertices(soma.coefficients(for: x.somaTarget, bust: SomaModel.typicalBust(female: sex == .female, chest: x.chest)))
        }
        let her = body(.female), him = body(.male)
        #expect(soma.bust(her) > soma.bust(him) + 4)
        #expect(abs(soma.measure(her)[1] - 92) < 1.5)
        #expect(abs(soma.measure(him)[1] - 92) < 1.5)
    }

    /// Long sleeves on a top that fits aren't tight: they hang off an arm held out, and
    /// that pull isn't the arm (every long sleeve read "very tight" before).
    @Test func sleevesOfAFittingTopAreNotTight() {
        for style in [Avatar.GarmentFit.Style.plain, .jacket, .coat] {
            var f = Avatar.GarmentFit(kind: .top(longSleeves: true)); f.style = style
            f.chestEase = 14; f.waistEase = 16; f.hipEase = 16; f.sleeveDelta = 2
            let report = Avatar(m, garment: f, detail: .preview).fitReport
            for zone in [FitZone.sleeve, .elbow] {
                #expect((report[zone]?.tension ?? .comfortable) < .slightlyTight, "\(style) \(zone)")
            }
        }
    }

    /// A coat ends above the knee and a T-shirt below the hips, with no length given.
    @Test func coatsAreLong() {
        var tee = Avatar.GarmentFit(kind: .top(longSleeves: false))
        var coat = Avatar.GarmentFit(kind: .top(longSleeves: true)); coat.style = .coat
        tee.chestEase = 12; coat.chestEase = 20
        func hem(_ f: Avatar.GarmentFit) -> Float { Avatar(m, garment: f, detail: .preview).layers[0].mesh.positions.map(\.y).min() ?? 0 }
        let model = BodyModel.make(m)
        #expect(hem(tee) > model.crotchY - 0.05)
        #expect(hem(coat) < model.kneeY + 0.15)
    }
}

@Suite struct Placements {
    let m = Avatar.Measurements(height: 173, chest: 92, waist: 82, hip: 92, thigh: 56,
                                shoulderWidth: 37, armLength: 56, inseam: 81)

    /// Trouser legs 3 cm long end 3 cm past the ankle; 15 cm long reach the floor.
    @Test func trouserLegsAgainstTheAnkle() throws {
        var f = Avatar.GarmentFit(kind: .trousers); f.lengthDelta = 3
        let legs = try #require(Avatar(m, garment: f, detail: .preview).layers[0].placements.first)
        #expect(legs.edge == .legs && legs.landmark == .ankle && abs(legs.offsetCm - 3) < 0.5)
        f.lengthDelta = 15
        #expect(Avatar(m, garment: f, detail: .preview).layers[0].placements.first?.landmark == .floor)
    }

    /// A skirt's hem is said against the knee; a mini skirt's well above it.
    @Test func skirtHemAgainstTheKnee() throws {
        var f = Avatar.GarmentFit(kind: .skirt); f.waistEase = 1; f.hipEase = 8
        let regular = try #require(Avatar(m, garment: f, detail: .preview).layers[0].placements.first)
        #expect(regular.landmark == .knee && regular.offsetCm < 0 && regular.offsetCm > -10)
        f.hemOffset = -0.065 * 173
        let mini = try #require(Avatar(m, garment: f, detail: .preview).layers[0].placements.first)
        #expect([.midThigh, .knee].contains(mini.landmark) && mini.usual)
    }

    /// Long sleeves 2 cm long end 2 cm past the wrist.
    @Test func sleevesAgainstTheWrist() {
        var f = Avatar.GarmentFit(kind: .top(longSleeves: true)); f.sleeveDelta = 2
        let sleeve = Avatar(m, garment: f, detail: .preview).layers[0].placements.first { $0.edge == .sleeve }
        #expect(sleeve?.landmark == .wrist)
        #expect(abs((sleeve?.offsetCm ?? 0) - 2) < 0.5)
    }
}

@Suite struct ShortsAndCrops {
    let m = Avatar.Measurements(height: 170, chest: 90, waist: 74, hip: 96, thigh: 56,
                                shoulderWidth: 36, armLength: 55, inseam: 78)

    /// Shorts cut to mid-thigh say so, against the thigh, not "50 cm above the ankle".
    @Test func shortsEndAtTheThigh() throws {
        var f = Avatar.GarmentFit(kind: .trousers); f.hemOffset = -0.335 * 170
        let legs = try #require(Avatar(m, garment: f, detail: .preview).layers[0].placements.first)
        #expect([.midThigh, .knee].contains(legs.landmark))
        #expect(legs.usual)
    }

    /// A crop top's hem is up at the waist.
    @Test func cropTopEndsAtTheWaist() throws {
        var f = Avatar.GarmentFit(kind: .top(longSleeves: false)); f.hemOffset = -0.075 * 170
        let hem = try #require(Avatar(m, garment: f, detail: .preview).layers[0].placements.first { $0.edge == .hem })
        #expect([.waist, .hips].contains(hem.landmark))
    }
}
