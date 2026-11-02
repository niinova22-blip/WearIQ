import Foundation
import Testing
@testable import BodyMeasurementEngine

/// The person segmentation sometimes takes in a chair or a coat rack touching the
/// person; only what belongs to the skeleton stays.
@Suite struct PersonIsolationTests {
    let w = 200, h = 400
    let joints: [BodyJoint: Point2D] = [
        .nose: Point2D(100, 50), .neck: Point2D(100, 80), .root: Point2D(100, 200),
        .leftShoulder: Point2D(80, 85), .rightShoulder: Point2D(120, 85),
        .leftElbow: Point2D(70, 140), .rightElbow: Point2D(130, 140),
        .leftWrist: Point2D(68, 190), .rightWrist: Point2D(132, 190),
        .leftHip: Point2D(88, 200), .rightHip: Point2D(112, 200),
        .leftKnee: Point2D(90, 290), .rightKnee: Point2D(110, 290),
        .leftAnkle: Point2D(90, 375), .rightAnkle: Point2D(110, 375),
    ]

    func person(plus extra: (Int, Int) -> Bool) -> BinaryMask {
        var bits = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let body = (abs(x - 100) <= 22 && (82...210).contains(y))       // torso
                    || (abs(x - 100) <= 14 && (30...82).contains(y))            // head
                    || ((abs(x - 74) <= 6 || abs(x - 126) <= 6) && (85...200).contains(y))  // arms
                    || ((abs(x - 90) <= 8 || abs(x - 110) <= 8) && (200...390).contains(y)) // legs
                bits[y * w + x] = body || extra(x, y)
            }
        }
        return BinaryMask(width: w, height: h, bits: bits)
    }

    func count(_ m: BinaryMask, _ xs: Range<Int>, _ ys: Range<Int>) -> Int {
        ys.reduce(0) { sum, y in sum + xs.filter { m[$0, y] }.count }
    }

    @Test func chairTouchingTheBodyIsCut() {
        // A chair back pressed against the right side, from hip to knee, reaching far out.
        let mask = person { x, y in (122...199).contains(x) && (180...300).contains(y) }
        let clean = mask.isolatingPerson(joints: joints)
        #expect(count(clean, 172..<200, 180..<300) == 0)
        #expect(count(clean, 122..<200, 180..<300) < count(mask, 122..<200, 180..<300) * 2 / 3)
        // The body is all still there.
        let bare = person { _, _ in false }
        #expect(count(clean, 0..<w, 0..<h) >= count(bare, 0..<w, 0..<h))
        #expect(clean[100, 150] && clean[90, 350] && clean[74, 150] && clean[100, 40])
    }

    @Test func separateBlobIsDropped() {
        let mask = person { x, y in (2...20).contains(x) && (10...60).contains(y) }
        let clean = mask.isolatingPerson(joints: joints)
        #expect(count(clean, 0..<25, 0..<70) == 0)
        #expect(mask.largestComponent()[100, 150])
        #expect(!mask.largestComponent()[10, 30])
    }
}
