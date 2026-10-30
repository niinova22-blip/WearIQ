import Foundation
import Testing
@testable import AvatarEngine

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
        let model = BodyModel(me)
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
        let width = { (a: Avatar) in a.garment!.positions.filter { abs($0.y - 1.26) < 0.02 && abs($0.z) < 0.05 }.map(\.x).max()! }
        #expect(width(oversized) > width(regular))
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
        let model = BodyModel(me)
        let inside = avatar.garment!.positions.filter { model.distance($0) < -0.004 }
        #expect(Float(inside.count) / Float(avatar.garment!.positions.count) < 0.02)
    }

    @Test func landmarksSitOnTheSurface() {
        let avatar = Avatar(me, detail: quick)
        let model = BodyModel(me)
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
