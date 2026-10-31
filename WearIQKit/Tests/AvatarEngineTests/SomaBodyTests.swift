import Foundation
import Testing
@testable import AvatarEngine

/// The SOMA-X body: loaded from the bundle, shaped to the measurements, measured back.
@Suite struct SomaBodyTests {
    let man = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                  shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)
    let woman = Avatar.Measurements(height: 163, chest: 92, waist: 74, hip: 101, thigh: 58,
                                    shoulderWidth: 36, armLength: 53, inseam: 75)
    let large = Avatar.Measurements(height: 180, chest: 118, waist: 112, hip: 114, thigh: 66,
                                    shoulderWidth: 43, armLength: 60, inseam: 82)

    @Test func modelLoads() throws {
        let model = try #require(SomaModel.shared)
        #expect(model.mean.count == 4505)
        #expect(model.components == 32)
        #expect(model.triangles.count == 9006 * 3)
        #expect(model.calibration[5] > 1 && model.calibration[6] > 1)
    }

    /// The body built for a set of measurements measures as asked, within a centimetre
    /// for the girths and lengths (the linear model's error, then corrected twice).
    @Test(arguments: [0, 1, 2])
    func bodyMeasuresAsAsked(_ which: Int) throws {
        let model = try #require(SomaModel.shared)
        let m = [man, woman, large][which]
        let got = model.measure(model.vertices(model.coefficients(for: m.somaTarget)))
        for (i, (want, have)) in zip(m.somaTarget, got).enumerated() {
            #expect(abs(want - have) < 1.2, "measurement \(i): wanted \(want), built \(have)")
        }
    }

    /// Measured on both sides, so nothing pulls it lopsided.
    @Test func bodyIsSymmetric() throws {
        let model = try #require(SomaModel.shared)
        let v = model.vertices(model.coefficients(for: woman.somaTarget))
        let xs = v.map(\.x)
        #expect(abs((xs.max() ?? 0) + (xs.min() ?? 0)) < 0.004)
    }

    /// Impossible combinations still give a body, the nearest plausible one.
    @Test func impossibleMeasurementsStayHuman() throws {
        let model = try #require(SomaModel.shared)
        let odd = Avatar.Measurements(height: 150, chest: 140, waist: 60, hip: 70, thigh: 80,
                                      shoulderWidth: 55, armLength: 40, inseam: 90)
        let c = model.coefficients(for: odd.somaTarget)
        #expect(c.allSatisfy { abs($0) <= 3.5 })
        let body = BodyModel(soma: model, odd)
        #expect(body.h > 1.4 && body.h < 1.6)
    }

    /// The distance field the garments rest on follows the skin that's shown: few skin
    /// points stand more than a centimetre out of it.
    @Test func fieldFollowsTheSkin() throws {
        let model = try #require(SomaModel.shared)
        let body = BodyModel(soma: model, man)
        let skin = try #require(body.surface).positions
        var out = 0, total = 0
        for (i, p) in skin.enumerated() where p.y > body.crotchY - 0.3 && p.y < body.armpitY {
            guard [.torso, .leftLeg, .rightLeg, .leftArm, .rightArm].contains(model.parts[i]) else { continue }
            total += 1
            if body.distance(p) > 0.01 { out += 1 }
        }
        #expect(total > 300)
        #expect(Double(out) / Double(total) < 0.01)
    }

    /// Levels in the order they are on a body, and the body standing on the floor.
    @Test func levelsInOrder() throws {
        let model = try #require(SomaModel.shared)
        for m in [man, woman, large] {
            let b = BodyModel(soma: model, m)
            #expect(b.ankleY < b.kneeY && b.kneeY < b.crotchY && b.crotchY < b.hipY && b.hipY < b.waistY)
            #expect(b.waistY < b.chestY && b.chestY < b.armpitY && b.armpitY < b.shoulderY && b.shoulderY < b.headY)
            #expect(abs(b.h * 100 - Float(m.height)) < 1)
            #expect(b.arms[0].dir.x > 0 && b.arms[1].dir.x < 0)
            #expect(b.legs[0].knee.x > 0 && b.legs[1].knee.x < 0)
        }
    }
}
