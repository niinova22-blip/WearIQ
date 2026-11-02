import Foundation
import Testing
@testable import AvatarEngine
@testable import BodyMeasurementEngine
import WearIQCore

/// Writes the synthetic filmed-turn data set the girth model is trained on
/// (scripts/scan_training/train.py): every ANSUR II subject (or `SCAN_LIMIT` of them),
/// its body built with SOMA-X and filmed turning (`ScanSimulator`), the features the
/// phone can compute, the current engine's girths and the mesh's tape girths.
///
/// The split is by subject (`subjectid` hashed: 70% train, 15% validation, 15% test), so
/// no person's body is in two of them, whatever the number of recordings per subject
/// (`SCAN_REPEATS`, default 1; test subjects always get one).
///
/// `SCAN_DOMAIN` (normal, shifted, wide, unseen; see `ScanSimulator.Domain`) and
/// `SCAN_SOURCE=nhanes` choose the conditions and the bodies.
///
/// `SCAN_DATA=path.csv swift test --scratch-path .build-opt -Xswiftc -O --filter ScanDataExport`
@Suite struct ScanDataExport {
    final class Rows: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var rows: [(Int, String)] = []
        func add(_ key: Int, _ s: String) { lock.lock(); rows.append((key, s)); lock.unlock() }
    }

    static func split(_ id: Int) -> String {
        var h = UInt64(truncatingIfNeeded: id) &* 0x9E37_79B9_7F4A_7C15
        h ^= h >> 29
        let b = Int(h % 100)
        return b < 70 ? "train" : b < 85 ? "val" : "test"
    }

    static let featureCount = 27

    static var header: String {
        var cols = ["subject", "sex", "split", "repeat", "height", "weight", "age",
                    "ansur_chest", "ansur_waist", "ansur_hip", "ansur_thigh",
                    "mesh_chest", "mesh_waist", "mesh_hip", "mesh_thigh",
                    "old_chest", "old_waist", "old_hip", "hair", "distance", "cam_height", "frames", "top_frac", "floor_frac"]
        for level in ScanSimulator.levels {
            for k in ScanSimulator.offsets.indices {
                for f in ["mean", "cos2", "sin2", "cos4"] { cols.append("\(level.rawValue)_\(k)_\(f)") }
            }
        }
        // Engine C's feature vectors, as the phone computes them.
        for level in ScanSimulator.levels {
            for i in 0..<Self.featureCount { cols.append("f_\(level.rawValue)_\(i)") }
        }
        return cols.joined(separator: ",")
    }

    @Test func export() throws {
        guard let path = ProcessInfo.processInfo.environment["SCAN_DATA"] else { return }
        let model = try #require(SomaModel.shared)
        let limit = ProcessInfo.processInfo.environment["SCAN_LIMIT"].flatMap(Int.init) ?? .max
        let repeats = ProcessInfo.processInfo.environment["SCAN_REPEATS"].flatMap(Int.init) ?? 1
        let env = ProcessInfo.processInfo.environment
        let domain = ScanSimulator.Domain(rawValue: env["SCAN_DOMAIN"] ?? "normal") ?? .normal
        var subjects: [([String: String], BodySex)] = []
        if env["SCAN_SOURCE"] == "nhanes" {
            // US civilians (NHANES 2017–2020) with BMI 30 and over, beyond most of ANSUR:
            // height, weight, waist and hip measured; the other targets the ANSUR
            // relations' estimate (the mesh's own girths are the labels either way).
            let rows = Population.csv("NHANES_2017_2020_adults.csv")
            for (i, r) in rows.enumerated() {
                guard let h = Double(r["height"] ?? ""), let w = Double(r["weight"] ?? ""), w / pow(h / 100, 2) >= 30,
                      let waist = Double(r["waist"] ?? ""), let hip = Double(r["hip"] ?? "") else { continue }
                let sex: BodySex = r["sex"] == "male" ? .male : .female
                let prior = AnthropometricPrior().estimate(heightCm: h, weightKg: w, sex: sex, ageYears: Double(r["age"] ?? ""))
                let observed: [BodyDimension: MeasuredValue] = [.waist: MeasuredValue(cm: waist, uncertaintyCm: 1, source: .manual),
                                                                .hip: MeasuredValue(cm: hip, uncertaintyCm: 1, source: .manual)]
                let g = AnthropometricPrior.conditioned([.chest, .thigh], estimates: prior, observed: observed, sex: sex)
                guard let chest = g[.chest]?.cm ?? prior[.chest]?.cm, let thigh = g[.thigh]?.cm ?? prior[.thigh]?.cm,
                      let shoulder = prior[.shoulderWidth]?.cm, let arm = prior[.armLength]?.cm, let inseam = prior[.inseam]?.cm
                else { continue }
                // In ANSUR's columns and units (mm, kg × 10), split "test".
                subjects.append(([
                    "subjectid": "\(900_000 + i)", "stature": "\(h * 10)", "chestcircumference": "\(chest * 10)",
                    "waistcircumference": "\(waist * 10)", "buttockcircumference": "\(hip * 10)", "thighcircumference": "\(thigh * 10)",
                    "biacromialbreadth": "\(shoulder * 10)", "acromionradialelength": "\(arm * 10 * 0.56)",
                    "radialestylionlength": "\(arm * 10 * 0.44)", "crotchheight": "\(inseam * 10)", "weightkg": "\(w * 10)",
                    "age": r["age"] ?? "", "forceSplit": "test",
                ], sex))
            }
        } else {
            for (file, sex) in [("ANSUR_II_MALE_Public.csv", BodySex.male), ("ANSUR_II_FEMALE_Public.csv", .female)] {
                subjects += Population.csv(file).map { ($0, sex) }
            }
        }
        let chosen = Array(subjects.prefix(limit))
        let out = Rows()
        DispatchQueue.concurrentPerform(iterations: chosen.count) { n in
            let (r, sex) = chosen[n]
            func d(_ k: String) -> Double { Double(r[k] ?? "") ?? 0 }
            let id = Int(d("subjectid"))
            let split = r["forceSplit"] ?? Self.split(id)
            let target = [d("stature") / 10, d("chestcircumference") / 10, d("waistcircumference") / 10,
                          d("buttockcircumference") / 10, d("thighcircumference") / 10, d("biacromialbreadth") / 10,
                          (d("acromionradialelength") + d("radialestylionlength")) / 10, d("crotchheight") / 10]
            guard target.allSatisfy({ $0 > 0 }) else { return }
            let bust = SomaModel.typicalBust(female: sex == .female, chest: target[1])
            let v = model.body(for: target, bust: bust)
            let truth = model.measure(v)
            let sim = ScanSimulator(model: model, vertices: v)
            var rng = ScanSimulator.RNG(state: UInt64(id) &* 1_000_003 &+ 17)
            for rep in 0..<(split == "test" ? 1 : repeats) {
                let rec = sim.record(heightCm: truth[0], rng: &rng, off: Set((env["SCAN_OFF"] ?? "").split(separator: ",").map(String.init)),
                                     domain: domain)
                guard rec.turn.isComplete else { continue }
                let old = rec.turn.girths()
                let angles = rec.turn.angles()
                var cells: [String] = [
                    "\(id)", sex.rawValue, split, "\(rep)", f(truth[0]), f(d("weightkg") / 10), f(d("age")),
                    f(target[1]), f(target[2]), f(target[3]), f(target[4]),
                    f(truth[1]), f(truth[2]), f(truth[3]), f(truth[4]),
                    f(old[.chest]?.cm), f(old[.waist]?.cm), f(old[.hip]?.cm),
                    f(rec.hairCm), f(rec.distance), f(rec.cameraHeight), "\(rec.turn.samples.count)",
                    String(format: "%.5f", rec.topFraction), String(format: "%.5f", rec.floorFraction),
                ]
                for level in ScanSimulator.levels {
                    for k in ScanSimulator.offsets.indices {
                        if let h = LearnedGirthModel.harmonics(rec.widths[level]![k], angles: angles) {
                            cells += [f(h.mean), f(h.cos2), f(h.sin2), f(h.cos4)]
                        } else {
                            cells += ["", "", "", ""]
                        }
                    }
                }
                let features = LearnedGirthModel.features(rec.turn, heightCm: truth[0], weightKg: d("weightkg") / 10, sex: sex)
                for level in ScanSimulator.levels {
                    let f = features[level] ?? []
                    cells += (0..<Self.featureCount).map { $0 < f.count ? String(format: "%.6g", f[$0]) : "" }
                }
                out.add(n * 10 + rep, cells.joined(separator: ","))
            }
        }
        let text = ([Self.header] + out.rows.sorted { $0.0 < $1.0 }.map(\.1)).joined(separator: "\n") + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("wrote \(out.rows.count) recordings of \(chosen.count) subjects to \(path)")
    }

    func f(_ x: Double?) -> String { x.map { String(format: "%.3f", $0) } ?? "" }
}
