import Foundation
import Testing
@testable import AvatarEngine
@testable import BodyMeasurementEngine
import WearIQCore

/// The avatar shaped by the scan's silhouettes looks more like the person than one built
/// from the eight measurements alone.
///
/// Bodies drawn at random from the SOMA-X shape space (learned from SizeUSA scans, so
/// real-looking people, each different beyond their measurements) are filmed turning
/// (`ScanSimulator`, with the frames' width profiles). The eight directions' profiles go
/// through the silhouette fit; its shape then guides the avatar built from the same
/// eight measurements. The shape error is the torso's per-vertex distance from the
/// filmed body (both meshes share the model's vertices), centred.
@Suite struct ShapeFromScanTests {
    @Test func scanShapedAvatarIsCloserToThePerson() throws {
        let model = try #require(SomaModel.shared)
        var rng = ScanSimulator.RNG(state: 2026_11_05)
        let torso = model.parts.indices.filter { model.parts[$0] == .torso }
        var plainErrors: [Double] = [], shapedErrors: [Double] = []
        for _ in 0..<24 {
            let c = (0..<model.components).map { _ in max(-2.5, min(2.5, rng.gaussian())) }
            let person = model.vertices(c)
            let truth = model.measure(person)
            guard truth.allSatisfy({ $0 > 0 }) else { continue }
            var filmRng = ScanSimulator.RNG(state: rng.next())
            let rec = ScanSimulator(model: model, vertices: person).record(heightCm: truth[0], rng: &filmRng, stops: true)
            guard rec.turn.isComplete else { continue }
            let profiles = rec.turn.stationProfiles()
            var input = SilhouetteBodyFit.Input(profiles: profiles, heightCm: truth[0])
            input.start = Avatar.Measurements(height: truth[0], chest: truth[1], waist: truth[2], hip: truth[3],
                                              thigh: truth[4], shoulderWidth: truth[5], armLength: truth[6], inseam: truth[7])
            guard let fitted = SilhouetteBodyFit.fit(input) else { continue }
            let plain = model.body(for: truth)
            let shaped = model.body(for: truth, prior: fitted.coefficients)
            plainErrors.append(Self.torsoError(plain, person, torso))
            shapedErrors.append(Self.torsoError(shaped, person, torso))
            // The measurements still hold.
            let got = model.measure(shaped)
            for i in 1...4 { #expect(abs(got[i] - truth[i]) < 1.0, "girth \(i): \(got[i]) vs \(truth[i])") }
        }
        try #require(plainErrors.count >= 18)
        let plain = plainErrors.reduce(0, +) / Double(plainErrors.count)
        let shaped = shapedErrors.reduce(0, +) / Double(shapedErrors.count)
        let better = zip(shapedErrors, plainErrors).filter { $0 < $1 }.count
        print(String(format: "torso shape error: from measurements %.2f cm, from the scan %.2f cm; closer for %d of %d",
                     plain, shaped, better, plainErrors.count))
        #expect(shaped < plain * 0.9)
        #expect(better * 3 >= plainErrors.count * 2)
    }

    /// RMS distance (cm) between the same torso vertices, each mesh centred on its torso.
    static func torsoError(_ a: [Vec3], _ b: [Vec3], _ idx: [Int]) -> Double {
        func centre(_ v: [Vec3]) -> Vec3 {
            var s = Vec3(0, 0, 0)
            for i in idx { s = s + v[i] }
            return s * (1 / Float(idx.count))
        }
        let ca = centre(a), cb = centre(b)
        var sum = 0.0
        for i in idx {
            let d = (a[i] - ca) - (b[i] - cb)
            sum += Double(d.dot(d))
        }
        return (sum / Double(idx.count)).squareRoot() * 100
    }
}
