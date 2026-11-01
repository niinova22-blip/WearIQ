import Foundation
import Testing
@testable import BodyMeasurementEngine

@Suite struct TurnRecordingTests {
    /// Silhouette width of an elliptical section (half-axes a, b) seen at angle θ.
    func width(_ a: Double, _ b: Double, _ theta: Double) -> Double {
        2 * ((a * cos(theta)) * (a * cos(theta)) + (b * sin(theta)) * (b * sin(theta))).squareRoot()
    }

    /// A turn filmed at 8 frames a second, faster through the back half than the front,
    /// with a little noise on the arm span.
    func record(duration: Double = 14, uneven: Bool = true, seed: UInt64 = 1) -> TurnRecording {
        var rng = TurnRNG(seed: seed)
        var rec = TurnRecording()
        let n = Int(duration * 8)
        for i in 0...n + 6 {
            let t = Double(i) / 8
            let u = min(1, t / duration)
            // Uneven speed: angle runs ahead in the middle of the turn.
            let theta = 2 * .pi * (uneven ? u + 0.08 * sin(2 * .pi * u) : u)
            let span = max(0.25, abs(cos(theta))) + Double.random(in: -0.04...0.04, using: &rng)
            rec.add(.init(time: t, spanRatio: span, widths: [.waist: width(16, 12, theta), .hip: width(17, 13, theta)]))
        }
        return rec
    }

    @Test func findsTheEightDirections() throws {
        let rec = record()
        #expect(rec.isComplete)
        let stations = rec.stations()
        for k in 0..<8 {
            let expected = width(16, 12, Double(k) * .pi / 4)
            let got = try #require(stations[k]?[.waist])
            #expect(abs(got - expected) / expected < 0.05, "direction \(k): \(got) vs \(expected)")
        }
    }

    @Test func girthFromTheTurnMatchesTheSection() throws {
        let rec = record()
        var scan = StationScan()
        for (k, widths) in rec.stations().enumerated() { if let widths { scan.record(widths, at: k) } }
        let waist = try #require(scan.girths()[.waist]?.cm)
        // Ramanujan's perimeter of the ellipse.
        let a = 16.0, b = 12.0, h = ((a - b) * (a - b)) / ((a + b) * (a + b))
        let perimeter = Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
        #expect(abs(waist - perimeter) / perimeter < 0.03)
    }

    @Test func notCompleteUntilRoundAgain() {
        var rec = TurnRecording()
        let full = record()
        for s in full.samples.prefix(full.samples.count * 2 / 3) { rec.add(s) }
        #expect(!rec.isComplete)
        #expect(rec.progress > 0.4 && rec.progress < 1)
    }

    @Test func tooFastIsCaught() {
        let rec = record(duration: 4, uneven: false)
        #expect(rec.tooFast)
        #expect(!rec.isComplete)
    }
}

struct TurnRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
