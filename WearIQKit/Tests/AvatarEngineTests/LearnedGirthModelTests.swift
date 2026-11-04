import Foundation
import Testing
@testable import AvatarEngine
@testable import BodyMeasurementEngine
import WearIQCore

/// Engine C on the phone's own code path, end to end: held-out ANSUR II people (the
/// test split, never trained on) filmed turning in conditions the model never saw
/// (`ScanSimulator.Domain.unseen`: the phone rolled off level, the user leaning, a
/// lopsided mask), against the current engine on the very same frames.
///
/// The bar: within the error docs/SCAN_TRAINING.md reports for these conditions, and
/// better than the current engine at every level. Since 2026-11-05 it corrects the
/// production scan (`LearnedGirthModel.correct`), checked end to end below.
@Suite struct LearnedGirthModelTests {
    @Test func heldOutPeopleInUnseenConditions() throws {
        try #require(LearnedGirthModel.isTrained)
        let model = try #require(SomaModel.shared)
        var subjects: [([String: String], BodySex)] = []
        for (file, sex) in [("ANSUR_II_MALE_Public.csv", BodySex.male), ("ANSUR_II_FEMALE_Public.csv", .female)] {
            subjects += Population.csv(file).map { ($0, sex) }
        }
        // Every fourth test-split subject: about 230 people, a few seconds.
        let test = subjects.filter { ScanDataExport.split(Int(Double($0.0["subjectid"] ?? "") ?? 0)) == "test" }
            .enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
        var errC: [BodyLevel: [Double]] = [:], errA: [BodyLevel: [Double]] = [:]
        for (r, sex) in test {
            func d(_ k: String) -> Double { Double(r[k] ?? "") ?? 0 }
            let target = [d("stature") / 10, d("chestcircumference") / 10, d("waistcircumference") / 10,
                          d("buttockcircumference") / 10, d("thighcircumference") / 10, d("biacromialbreadth") / 10,
                          (d("acromionradialelength") + d("radialestylionlength")) / 10, d("crotchheight") / 10]
            let v = model.body(for: target, bust: SomaModel.typicalBust(female: sex == .female, chest: target[1]))
            let truth = model.measure(v)
            var rng = ScanSimulator.RNG(state: UInt64(d("subjectid")) &* 7_777_777 &+ 3)
            let rec = ScanSimulator(model: model, vertices: v).record(heightCm: truth[0], rng: &rng, domain: .unseen)
            guard rec.turn.isComplete else { continue }
            let c = LearnedGirthModel.girths(rec.turn, heightCm: truth[0], weightKg: d("weightkg") / 10, sex: sex)
            let a = rec.turn.girths()
            for (i, level) in [(1, BodyLevel.chest), (2, .waist), (3, .hip)] {
                if let x = c[level] { errC[level, default: []].append(x.cm - truth[i]) }
                if let x = a[level] { errA[level, default: []].append(x.cm - truth[i]) }
            }
        }
        func mae(_ e: [Double]) -> Double { e.map(abs).reduce(0, +) / Double(max(1, e.count)) }
        func bias(_ e: [Double]) -> Double { e.reduce(0, +) / Double(max(1, e.count)) }
        // Unseen conditions in docs/SCAN_TRAINING.md: about 1.5–2 cm; room for sampling.
        let limit: [BodyLevel: Double] = [.chest: 2.3, .waist: 2.4, .hip: 2.0]
        for level in LearnedGirthModel.levels {
            let c = try #require(errC[level]), a = try #require(errA[level])
            print(String(format: "%@: C n=%d MAE %.2f bias %+.2f | current n=%d MAE %.2f bias %+.2f",
                         level.rawValue, c.count, mae(c), bias(c), a.count, mae(a), bias(a)))
            #expect(c.count >= test.count * 9 / 10)
            #expect(mae(c) <= limit[level]!)
            #expect(abs(bias(c)) <= 0.8)
            #expect(mae(c) < mae(a))
        }
    }

    /// The scan as the app runs it: the eight stops from the turn, the every-frame fit,
    /// C's perspective factor over both, fused by `StationScan.girths`. Held-out ANSUR
    /// people in the usual conditions: no level more than 1 cm off on average (the plain
    /// scan reads men's chests about 4–5 cm small), and closer than the plain scan.
    @Test func productionScanWithPerspectiveCorrection() throws {
        try #require(LearnedGirthModel.isTrained)
        let model = try #require(SomaModel.shared)
        var subjects: [([String: String], BodySex)] = []
        for (file, sex) in [("ANSUR_II_MALE_Public.csv", BodySex.male), ("ANSUR_II_FEMALE_Public.csv", .female)] {
            subjects += Population.csv(file).map { ($0, sex) }
        }
        let test = subjects.filter { ScanDataExport.split(Int(Double($0.0["subjectid"] ?? "") ?? 0)) == "test" }
            .enumerated().filter { $0.offset % 6 == 1 }.map(\.element)
        var fixed: [String: [Double]] = [:], plain: [String: [Double]] = [:]
        for (r, sex) in test {
            func d(_ k: String) -> Double { Double(r[k] ?? "") ?? 0 }
            let target = [d("stature") / 10, d("chestcircumference") / 10, d("waistcircumference") / 10,
                          d("buttockcircumference") / 10, d("thighcircumference") / 10, d("biacromialbreadth") / 10,
                          (d("acromionradialelength") + d("radialestylionlength")) / 10, d("crotchheight") / 10]
            let v = model.body(for: target, bust: SomaModel.typicalBust(female: sex == .female, chest: target[1]))
            let truth = model.measure(v)
            var rng = ScanSimulator.RNG(state: UInt64(d("subjectid")) &* 31 &+ 11)
            let rec = ScanSimulator(model: model, vertices: v).record(heightCm: truth[0], rng: &rng)
            guard rec.turn.isComplete else { continue }
            var scan = StationScan()
            for (k, widths) in rec.turn.stations().enumerated() {
                if let widths { scan.record(widths, at: k) }
            }
            let girths = rec.turn.girths()
            scan.everyFrame = girths
            let before = scan.girths()
            LearnedGirthModel.correct(&scan, turn: rec.turn, plain: girths, heightCm: truth[0], weightKg: d("weightkg") / 10, sex: sex)
            let after = scan.girths()
            for (i, level) in [(1, BodyLevel.chest), (2, .waist), (3, .hip)] {
                let key = "\(sex.rawValue) \(level.rawValue)"
                if let x = after[level] { fixed[key, default: []].append(x.cm - truth[i]) }
                if let x = before[level] { plain[key, default: []].append(x.cm - truth[i]) }
            }
        }
        func mae(_ e: [Double]) -> Double { e.map(abs).reduce(0, +) / Double(max(1, e.count)) }
        func bias(_ e: [Double]) -> Double { e.reduce(0, +) / Double(max(1, e.count)) }
        for key in fixed.keys.sorted() {
            let f = fixed[key]!, p = plain[key] ?? []
            print(String(format: "%@: corrected MAE %.2f bias %+.2f | plain MAE %.2f bias %+.2f (n=%d)",
                         key, mae(f), bias(f), mae(p), bias(p), f.count))
            #expect(abs(bias(f)) <= 1.0, "\(key)")
            #expect(mae(f) <= mae(p) + 0.1, "\(key)")
        }
    }

    /// Without the rows around the levels (a recording from before engine C) it gives
    /// nothing rather than a guess.
    @Test func nothingWithoutTheRows() {
        var rec = TurnRecording()
        for i in 0..<120 {
            rec.add(.init(time: Double(i) / 10, spanRatio: abs(cos(Double(i) * 0.06)), widths: [.chest: 30, .waist: 27, .hip: 33]))
        }
        #expect(LearnedGirthModel.girths(rec, heightCm: 175, weightKg: 75, sex: .male).isEmpty)
    }
}
