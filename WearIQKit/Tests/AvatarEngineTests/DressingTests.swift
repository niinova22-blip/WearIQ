import Foundation
import Testing
@testable import AvatarEngine

@Suite struct DressingTests {
    let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                 shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)
    let animatedPreview = Avatar.Detail(body: 0.02, garment: 0.022, animated: true)

    func looseTee() -> Avatar.GarmentFit {
        var fit = Avatar.GarmentFit(kind: .top(longSleeves: false))
        fit.chestEase = 16; fit.waistEase = 20; fit.hipEase = 20
        fit.fabric = .cottonJersey
        return fit
    }

    @Test func garmentFallsOntoTheBodyAndSettles() {
        let start = Date()
        let avatar = Avatar(me, garment: looseTee(), detail: animatedPreview)
        let frames = avatar.garmentFrames
        print("frames \(frames.count), \(Date().timeIntervalSince(start)) s")
        #expect(frames.count >= 55)
        func meanY(_ f: [Vec3]) -> Float { f.reduce(0) { $0 + $1.y } / Float(f.count) }
        // Starts raised and comes down.
        #expect(meanY(frames[0]) > meanY(frames[frames.count - 1]) + 0.05)
        // Moves the most early on and comes to rest at the end.
        func motion(_ a: [Vec3], _ b: [Vec3]) -> Float { zip(a, b).reduce(0) { $0 + ($1.0 - $1.1).length } / Float(a.count) }
        let early = motion(frames[2], frames[6]), late = motion(frames[frames.count - 5], frames[frames.count - 2])
        print("early \(early) late \(late)")
        #expect(early > 5 * late)
        // Still moving well after the held parts are in place: it swings, not just stops.
        #expect(motion(frames[14], frames[18]) > 0.001)
        // Ends on the finished garment.
        #expect(frames.last! == avatar.garment!.positions)
    }

    @Test func droppedGarmentEndsOutsideTheBody() {
        let avatar = Avatar(me, garment: looseTee(), detail: animatedPreview)
        let model = BodyModel.make(me)
        let inside = avatar.garment!.positions.filter { model.distance($0) < -0.004 }
        #expect(Float(inside.count) / Float(avatar.garment!.positions.count) < 0.02)
        #expect(avatar.fitReport[.chest] != nil)
    }

    @Test func trousersToo() {
        var fit = Avatar.GarmentFit(kind: .trousers)
        fit.fabric = .denim
        let avatar = Avatar(me, garment: fit, detail: animatedPreview)
        #expect(avatar.garmentFrames.count >= 55)
        let model = BodyModel.make(me)
        let inside = avatar.garment!.positions.filter { model.distance($0) < -0.004 }
        #expect(Float(inside.count) / Float(avatar.garment!.positions.count) < 0.03)
    }
}
