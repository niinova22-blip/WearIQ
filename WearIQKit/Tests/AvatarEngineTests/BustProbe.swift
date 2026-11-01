import Foundation
import Testing
@testable import AvatarEngine

/// Diagnostic: how the bust (chest at the nipples minus the girth just under the
/// breasts) is spread over bodies drawn from the SOMA-X shape space. Run with PROBE=1.
@Suite struct BustProbe {
    @Test func distribution() throws {
        guard ProcessInfo.processInfo.environment["PROBE"] != nil else { return }
        let model = try #require(SomaModel.shared)
        var rng = SystemRandomNumberGenerator()
        func gauss() -> Double {
            let u = Double.random(in: 1e-9..<1, using: &rng), v = Double.random(in: 0..<1, using: &rng)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        for drop in [0.035, 0.05, 0.065] as [Float] {
            var values: [Double] = []
            for _ in 0..<300 {
                let c = (0..<model.components).map { _ in gauss() }
                let v = model.vertices(c)
                values.append(model.bust(v, drop: drop))
            }
            values.sort()
            let hist = stride(from: -4.0, to: 24, by: 2).map { lo in "\(Int(lo)):\(values.filter { $0 >= lo && $0 < lo + 2 }.count)" }
            print("drop \(drop): mean \(values.reduce(0, +) / Double(values.count)) p10 \(values[30]) p50 \(values[150]) p90 \(values[270])")
            print("  " + hist.joined(separator: " "))
        }
        print("mean body bust \(model.bust(model.mean, drop: 0.05))")
    }
}

@Suite struct SleeveProbe {
    @Test func whereSleevesStretch() {
        guard ProcessInfo.processInfo.environment["PROBE"] != nil else { return }
        let me = Avatar.Measurements(height: 173, chest: 90, waist: 83.5, hip: 89, thigh: 56.9,
                                     shoulderWidth: 37.6, armLength: 56.4, inseam: 83.4)
        let model = BodyModel.make(me)
        if let skin = model.surface {
            var bins = [Float](repeating: -1, count: 11)
            for p in skin.positions where p.x > 0.2 {
                let along = (p - model.arms[0].start).dot(model.arms[0].dir) / model.armLength
                guard along > 0, along < 1.1 else { continue }
                let b = min(10, Int(along * 10))
                bins[b] = max(bins[b], model.arms[0].limb.distance(p))
            }
            print("skin outside limb (cm):", bins.map { String(format: "%.1f", $0 * 100) })
        }
        for style in [Avatar.GarmentFit.Style.plain, .jacket] {
            var f = Avatar.GarmentFit(kind: .top(longSleeves: true)); f.style = style
            f.chestEase = 14; f.waistEase = 16; f.hipEase = 16; f.sleeveDelta = -5
            let d = model.dress(f, cell: 0.014)
            var bins = [[Float]](repeating: [], count: 10)
            for (i, p) in d.mesh.positions.enumerated() where p.x > 0.25 {
                let along = (p - model.arms[0].start).dot(model.arms[0].dir) / model.armLength
                let b = min(9, max(0, Int(along * 10)))
                bins[b].append(d.mesh.strain[i])
            }
            print(style, bins.map { b in b.isEmpty ? "-" : String(format: "%.2f", b.sorted()[b.count * 3 / 4]) })
        }
    }
}
