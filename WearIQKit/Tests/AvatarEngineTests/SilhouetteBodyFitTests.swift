import Foundation
import Testing
import WearIQCore
@testable import AvatarEngine

/// SYNTHETIC checks of the silhouette fit: bodies drawn from the SOMA-X shape space are
/// turned into stop profiles by the same projection the fit uses, with the errors a real
/// turn has (stops 5–8° off, clothing on every edge, noisy rows). This shows the fit
/// recovers a body it could represent; it says nothing about real people, whose
/// accuracy only the tape-measure validation records can show.
@Suite struct SilhouetteBodyFitTests {
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
        mutating func normal() -> Double {
            let u = max(1e-12, Double(next() >> 11) / Double(1 << 53)), v = Double(next() >> 11) / Double(1 << 53)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    /// The stop profiles a turn would give for this body.
    static func profiles(_ model: SomaModel, _ c: [Double], height: Double, clothing: Double, angleErrors: [Double],
                         noise: Double, rng: inout Generator) -> [StopProfile] {
        var input = SilhouetteBodyFit.Input(profiles: [], heightCm: height)
        input.clothingCm = (clothing, 0.3)
        let problem = SilhouetteBodyFit.Problem(model: model, input: input, stops: [])
        let s = problem.sections(c)
        // Widths as the turn reports them: scaled so the body has the typed height.
        let scale = height / s.height
        return (0..<8).map { station in
            let angle = Double(station) * .pi / 4 + angleErrors[station] * .pi / 180
            let torso = s.torso.map { points in
                points.flatMap { SilhouetteBodyFit.Problem.width($0, angle: angle) }
                    .map { ($0 + 2 * clothing) * scale + noise * rng.normal() }
            }
            var legs: [[Double]] = [], outer: [Double?] = []
            for row in s.legs {
                guard let row else { legs.append([]); outer.append(nil); continue }
                let each = row.compactMap { SilhouetteBodyFit.Problem.width($0, angle: angle) }
                legs.append(station % 4 == 0 && each.count == 2 ? each.map { ($0 + 2 * clothing) * scale + noise * rng.normal() } : [])
                outer.append(SilhouetteBodyFit.Problem.width(row[0] + row[1], angle: angle).map { ($0 + 2 * clothing) * scale })
            }
            return StopProfile(station: station, torso: torso, legs: legs, legsOuter: outer)
        }
    }

    /// The current method on the same profiles: π × mean width of the eight stops at
    /// the row nearest the level, less the clothing.
    static func cauchy(_ profiles: [StopProfile], fraction: Double, clothing: Double) -> Double? {
        guard let row = SilhouetteRows.torso.indices.min(by: { abs(SilhouetteRows.torso[$0] - fraction) < abs(SilhouetteRows.torso[$1] - fraction) }) else { return nil }
        let widths = profiles.compactMap { $0.torso[row] }
        guard widths.count == 8 else { return nil }
        return Double.pi * (widths.reduce(0, +) / 8 - 2 * clothing)
    }

    @Test func recoversSyntheticBodies() throws {
        let model = try #require(SomaModel.shared)
        var rng = Generator(state: 42)
        var errorsB: [String: [Double]] = [:], errorsA: [String: [Double]] = [:]
        for _ in 0..<3 {
            let truthC = (0..<model.components).map { _ in max(-2, min(2, rng.normal())) * (1 - 0.02) }
            let v = model.vertices(truthC)
            let truth = model.measure(v)
            let floor = v.map(\.y).min()!, top = v[model.points.top].y, h = top - floor
            func fraction(_ i: Int) -> Double { Double((top - v[i].y) / h) }
            let angles = (0..<8).map { _ in 6 * rng.normal() }
            let profiles = Self.profiles(model, truthC, height: truth[0], clothing: 0.3, angleErrors: angles, noise: 0.6, rng: &rng)
            var input = SilhouetteBodyFit.Input(profiles: profiles, heightCm: truth[0])
            input.clothingCm = (0.3, 0.3)
            let result = try #require(SilhouetteBodyFit.fit(input, model: model))
            for (r, d, landmark) in [(1, BodyDimension.chest, model.points.nipple), (2, .waist, model.points.navel), (3, .hip, model.points.buttock)] {
                let got = try #require(result.values[d])
                errorsB[d.rawValue, default: []].append(got.cm - truth[r])
                #expect(got.provenance == .observed)
                if let a = Self.cauchy(profiles, fraction: fraction(landmark), clothing: 0.3) {
                    errorsA[d.rawValue, default: []].append(a * model.calibration[r] - truth[r])
                }
            }
            errorsB["thigh", default: []].append(result.values[.thigh]!.cm - truth[4])
            #expect(result.rmsResidualCm < 2.5)
            // Model-only girths come with the model's mark.
            #expect(result.values[.upperArm]?.provenance == .model)
            #expect((20...45).contains(result.values[.upperArm]?.cm ?? 0))
            #expect((28...48).contains(result.values[.neck]?.cm ?? 0))
        }
        func mae(_ e: [Double]) -> Double { e.map(abs).reduce(0, +) / Double(max(1, e.count)) }
        for d in ["chest", "waist", "hip"] {
            print("SYNTHETIC \(d): silhouette fit MAE \(String(format: "%.2f", mae(errorsB[d] ?? []))) cm,"
                  + " π×mean width MAE \(String(format: "%.2f", mae(errorsA[d] ?? []))) cm")
            #expect(mae(errorsB[d] ?? []) < 2.0, "\(d)")
        }
        print("SYNTHETIC thigh: silhouette fit MAE \(String(format: "%.2f", mae(errorsB["thigh"] ?? []))) cm")
        #expect(mae(errorsB["thigh"] ?? []) < 3.0)
    }

    @Test func tooLittleToFit() throws {
        let model = try #require(SomaModel.shared)
        let one = StopProfile(station: 0, torso: [80], legs: [], legsOuter: [])
        #expect(SilhouetteBodyFit.fit(SilhouetteBodyFit.Input(profiles: [one], heightCm: 175), model: model) == nil)
    }

    /// Loose clothes: the fit doesn't pretend to know the body under them.
    @Test func looseClothesWidenTheRange() throws {
        let model = try #require(SomaModel.shared)
        var rng = Generator(state: 7)
        let c = [Double](repeating: 0, count: model.components)
        let height = model.measure(model.vertices(c))[0]
        let profiles = Self.profiles(model, c, height: height, clothing: 1.5, angleErrors: [Double](repeating: 0, count: 8),
                                     noise: 0.5, rng: &rng)
        var fitted = SilhouetteBodyFit.Input(profiles: profiles, heightCm: height)
        fitted.clothingCm = SilhouetteBodyFit.clothing(fitted: true, underwear: false)
        var everyday = fitted
        everyday.clothingCm = SilhouetteBodyFit.clothing(fitted: false, underwear: false)
        let sure = try #require(SilhouetteBodyFit.fit(fitted, model: model)?.values[.waist])
        let unsure = try #require(SilhouetteBodyFit.fit(everyday, model: model)?.values[.waist])
        #expect(unsure.sdCm > sure.sdCm)
    }
}
