import Foundation
import Testing
@testable import BodyMeasurementEngine

/// The floor-scale geometry on a made-up camera (no device): a phone held upright,
/// 1 m above the floor, looking at a person standing 2.6 m away.
@Suite struct FloorScaleTests {
    /// The back camera of an upright phone: sensor x points down the world, sensor y
    /// to the world's right, looking along −z; tilted down by `pitch` degrees.
    func camera(height: Double = 1.0, pitch: Double = 0) -> ARCameraModel {
        let a = pitch * .pi / 180
        // Rotation about the world x axis (negative pitch looks down).
        func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(v.x, v.y * cos(-a) - v.z * sin(-a), v.y * sin(-a) + v.z * cos(-a))
        }
        let x = rotate(SIMD3(0, -1, 0)), y = rotate(SIMD3(1, 0, 0)), z = rotate(SIMD3(0, 0, 1))
        return ARCameraModel(fx: 1500, fy: 1500, cx: 960, cy: 720, sensorWidth: 1920, sensorHeight: 1440,
                             transform: [x.x, x.y, x.z, 0, y.x, y.y, y.z, 0, z.x, z.y, z.z, 0, 0, height, 0, 1])
    }

    @Test(arguments: [0.0, 12.0])
    func heightAndDistance(pitch: Double) throws {
        let cam = camera(pitch: pitch)
        let setback = FloorScale.footSetback(statureCm: 175)
        let toe = SIMD3(0.0, 0, -2.6 + setback), top = SIMD3(0.0, 1.75, -2.6)
        let feet = try #require(cam.project(toe)), head = try #require(cam.project(top))
        // Upright picture: the head above the feet.
        #expect(head.v < feet.v && feet.v < cam.portraitHeight)
        let r = try #require(FloorScale.measure(camera: cam, floorY: 0, feet: feet, head: head, setbackM: setback))
        #expect(abs(r.statureCm - 175) < 0.01)
        #expect(abs(r.distanceM - 2.6) < 0.001)
        // Hips 30 cm wide at 1 m.
        let l = try #require(cam.project(SIMD3(-0.15, 1.0, -2.6))), rr = try #require(cam.project(SIMD3(0.15, 1.0, -2.6)))
        let w = try #require(FloorScale.width(camera: cam, reading: r, left: l, right: rr))
        #expect(abs(w - 0.30) < 1e-4)
    }

    @Test func setbackErrorCostsAboutOnePercent() throws {
        let cam = camera(pitch: 8)
        let toe = SIMD3(0.0, 0, -2.6 + 0.19), top = SIMD3(0.0, 1.75, -2.6)
        let feet = try #require(cam.project(toe)), head = try #require(cam.project(top))
        let r = try #require(FloorScale.measure(camera: cam, floorY: 0, feet: feet, head: head, setbackM: 0.16))
        #expect(abs(r.statureCm - 175) / 175 < 0.015)
    }

    @Test func impossibleGeometryIsRefused() throws {
        let cam = camera()
        // Feet above the horizon: the ray never meets the floor in front.
        #expect(FloorScale.measure(camera: cam, floorY: 0, feet: (720, 100), head: (720, 50), setbackM: 0.2) == nil)
        // A floor above the camera.
        let feet = try #require(cam.project(SIMD3(0, 0, -2.4)))
        #expect(FloorScale.measure(camera: cam, floorY: 1.5, feet: feet, head: (720, 100), setbackM: 0.2) == nil)
    }

    @Test func combineIsRobust() throws {
        let c = try #require(FloorScale.combine([174.8, 175.1, 175.0, 174.9, 182.0, 175.2]))
        #expect(abs(c.cm - 175.1) < 0.21 && c.sdCm < 1.5)
        #expect(FloorScale.combine([175, 176]) == nil)
    }
}

@Suite struct SilhouetteKeyPointsTests {
    /// A stick figure: head, body, two feet, and a hand held far out at shoulder height.
    func figure(cutFeet: Bool = false) -> BinaryMask {
        let w = 100, h = 200
        var bits = [Bool](repeating: false, count: w * h)
        func fill(_ xs: Range<Int>, _ ys: Range<Int>) { for y in ys where y < h { for x in xs { bits[y * w + x] = true } } }
        fill(46..<54, 20..<40)      // head
        fill(40..<60, 40..<120)     // body
        fill(5..<95, 50..<56)       // arms out
        fill(40..<48, 120..<(cutFeet ? 200 : 180))  // legs
        fill(52..<60, 120..<(cutFeet ? 200 : 180))
        return BinaryMask(width: w, height: h, bits: bits)
    }

    @Test func headAndFeet() throws {
        let p = try #require(SilhouetteKeyPoints.find(figure()))
        #expect(p.headV == 20 && p.headU == 50)
        #expect(p.feetV == 180 && p.feetU == 50 && !p.cutOff)
        #expect(try #require(SilhouetteKeyPoints.find(figure(cutFeet: true))).cutOff)
    }
}
