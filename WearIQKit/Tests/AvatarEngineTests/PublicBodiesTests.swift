import Foundation
import Testing
@testable import AvatarEngine
@testable import BodyMeasurementEngine
import WearIQCore

/// Real people whose measurements are public, against the three ways the app knows a
/// body: the height/weight estimate, the avatar built from measurements, and the
/// filmed-turn scan (simulated on the person's own body shape).
///
/// The data isn't in the repository (its licences don't clearly allow redistribution);
/// point the environment at local copies to run it:
/// - `BDIMS_CSV`: Heinz, Peterson, Johnson & Kerk (2003), "Exploring Relationships in
///   Body Dimensions", Journal of Statistics Education 11(2): 507 physically active
///   adults (247 men, 260 women) measured by tape. Its chest girth is at the nipples for
///   men but *above the breasts* for women, so women's chest isn't compared. Its waist
///   is the narrowest point; the app's waist is at the navel, which it lists too.
/// - `PUBLIC_FIGURES_JSON`: heights, weights and bust–waist–hip figures published for
///   actors and models: [{name, sex, height, weight, bust, waist, hip}]. Rounded,
///   often unverified; the waist is the narrowest point.
///
/// `PUBLIC_BODIES_REPORT` writes the report to a file.
@Suite(.serialized) struct PublicBodiesTests {
    static let env = ProcessInfo.processInfo.environment

    struct Person {
        var name: String
        var sex: BodySex
        var age: Double?
        var height: Double
        var weight: Double
        /// Tape values in the app's terms (waist = at the navel), where known.
        var tape: [BodyDimension: Double]
        /// The narrowest waist, when given.
        var naturalWaist: Double?
    }

    static func bdims(_ path: String) -> [Person] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.split(separator: ",").map(String.init) else { return [] }
        return lines.dropFirst().enumerated().compactMap { i, line in
            let cells = line.split(separator: ",").map { Double($0) ?? .nan }
            guard cells.count == header.count else { return nil }
            let r = Dictionary(uniqueKeysWithValues: zip(header, cells))
            let sex: BodySex = r["sex"] == 1 ? .male : .female
            var tape: [BodyDimension: Double] = [
                .waist: r["nav_gi"]!, .hip: r["hip_gi"]!, .thigh: r["thi_gi"]!, .shoulderWidth: r["bia_di"]!,
                .calf: r["cal_gi"]!, .ankle: r["ank_gi"]!, .wrist: r["wri_gi"]!, .forearm: r["for_gi"]!,
            ]
            if sex == .male { tape[.chest] = r["che_gi"]! }
            return Person(name: "bdims #\(i + 1)", sex: sex, age: r["age"], height: r["hgt"]!, weight: r["wgt"]!,
                          tape: tape, naturalWaist: r["wai_gi"])
        }
    }

    static func figures(_ path: String) -> [Person] {
        guard let data = FileManager.default.contents(atPath: path),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let h = r["height"] as? Double, let w = r["weight"] as? Double,
                  let sex = (r["sex"] as? String).flatMap(BodySex.init(rawValue:)) else { return nil }
            var tape: [BodyDimension: Double] = [:]
            if let b = r["bust"] as? Double { tape[.chest] = b }
            if let hip = r["hip"] as? Double { tape[.hip] = hip }
            return Person(name: r["name"] as? String ?? "?", sex: sex, age: nil, height: h, weight: w, tape: tape,
                          naturalWaist: r["waist"] as? Double)
        }
    }

    struct Tally {
        var errors: [String: [Double]] = [:]
        mutating func add(_ key: String, _ e: Double) { errors[key, default: []].append(e) }

        func report(_ title: String) -> String {
            var lines = ["## \(title)", "| | n | bias | MAE | p90 abs |", "|---|---|---|---|---|"]
            for key in errors.keys.sorted() {
                let e = errors[key]!
                let abs = e.map(Swift.abs).sorted()
                let bias = e.reduce(0, +) / Double(e.count), mae = abs.reduce(0, +) / Double(abs.count)
                lines.append(String(format: "| %@ | %d | %+.2f | %.2f | %.2f |", key, e.count, bias, mae, abs[Int(0.9 * Double(abs.count - 1))]))
            }
            return lines.joined(separator: "\n") + "\n"
        }

        func bias(_ key: String) -> Double? { errors[key].map { $0.reduce(0, +) / Double($0.count) } }
        func mae(_ key: String) -> Double? { errors[key].map { $0.map(Swift.abs).reduce(0, +) / Double($0.count) } }
    }

    static func bmiBand(_ p: Person) -> String {
        let bmi = p.weight / pow(p.height / 100, 2)
        return bmi < 22 ? "BMI<22" : bmi < 26 ? "BMI 22-26" : "BMI 26+"
    }

    /// Height and weight only: the estimate a shopper gets before scanning.
    static func estimates(_ people: [Person]) -> Tally {
        var t = Tally()
        for p in people {
            let prior = AnthropometricPrior().estimate(heightCm: p.height, weightKg: p.weight, sex: p.sex, ageYears: p.age)
            for (d, cm) in p.tape {
                guard let est = prior[d]?.cm else { continue }
                t.add("\(p.sex.rawValue) \(d.rawValue)", est - cm)
                if [.chest, .waist, .hip].contains(d) { t.add("\(p.sex.rawValue) \(d.rawValue) \(bmiBand(p))", est - cm) }
            }
        }
        return t
    }

    /// The avatar built from the person's measurements (the rest estimated as the app
    /// does), measured back.
    static func avatars(_ people: [Person], model: SomaModel) -> (Tally, [String]) {
        var t = Tally()
        var worst: [(Double, String)] = []
        let names = ["height", "chest", "waist", "hip", "thigh", "shoulder", "arm", "inseam"]
        for p in people {
            let prior = AnthropometricPrior().estimate(heightCm: p.height, weightKg: p.weight, sex: p.sex, ageYears: p.age)
            let observed = p.tape.mapValues { MeasuredValue(cm: $0, uncertaintyCm: 1, source: .manual) }
            let filled = AnthropometricPrior.conditioned([.chest, .waist, .hip, .thigh], estimates: prior, observed: observed, sex: p.sex)
            func v(_ d: BodyDimension) -> Double? { p.tape[d] ?? filled[d]?.cm ?? prior[d]?.cm }
            guard let chest = v(.chest), let waist = v(.waist), let hip = v(.hip), let thigh = v(.thigh),
                  let shoulder = v(.shoulderWidth), let arm = v(.armLength), let inseam = v(.inseam) else { continue }
            let target = [p.height, chest, waist, hip, thigh, shoulder, arm, inseam]
            let got = model.measure(model.body(for: target, bust: SomaModel.typicalBust(female: p.sex == .female, chest: chest)))
            for (i, name) in names.enumerated() {
                // Only what was really measured counts; estimated inputs are just scaffolding.
                let measured = i == 0 || [1: BodyDimension.chest, 2: .waist, 3: .hip, 4: .thigh, 5: .shoulderWidth][i].map { p.tape[$0] != nil } ?? false
                guard measured else { continue }
                let e = got[i] - target[i]
                t.add("\(p.sex.rawValue) \(name)", e)
                if abs(e) > 2.5 {
                    worst.append((abs(e), "\(p.name) \(p.sex.rawValue) \(Int(p.height))cm \(Int(p.weight))kg: \(name) wanted \(String(format: "%.1f", target[i])) built \(String(format: "%.1f", got[i]))"))
                }
            }
        }
        return (t, worst.sorted { $0.0 > $1.0 }.prefix(20).map(\.1))
    }

    /// The filmed turn, simulated on each person's body, against the mesh it filmed and
    /// against the person's own tape.
    static func scans(_ people: [Person], model: SomaModel) -> Tally {
        final class Box: @unchecked Sendable { var t = Tally(); let lock = NSLock() }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: people.count) { n in
            let p = people[n]
            let prior = AnthropometricPrior().estimate(heightCm: p.height, weightKg: p.weight, sex: p.sex, ageYears: p.age)
            let observed = p.tape.mapValues { MeasuredValue(cm: $0, uncertaintyCm: 1, source: .manual) }
            let filled = AnthropometricPrior.conditioned([.chest, .waist, .hip, .thigh], estimates: prior, observed: observed, sex: p.sex)
            func v(_ d: BodyDimension) -> Double? { p.tape[d] ?? filled[d]?.cm ?? prior[d]?.cm }
            guard let chest = v(.chest), let waist = v(.waist), let hip = v(.hip), let thigh = v(.thigh),
                  let shoulder = v(.shoulderWidth), let arm = v(.armLength), let inseam = v(.inseam) else { return }
            let target = [p.height, chest, waist, hip, thigh, shoulder, arm, inseam]
            let verts = model.body(for: target, bust: SomaModel.typicalBust(female: p.sex == .female, chest: chest))
            let truth = model.measure(verts)
            let sim = ScanSimulator(model: model, vertices: verts)
            var rng = ScanSimulator.RNG(state: UInt64(n) &* 7_919 &+ 3)
            let rec = sim.record(heightCm: truth[0], rng: &rng, off: Set((env["SCAN_OFF"] ?? "").split(separator: ",").map(String.init)))
            guard rec.turn.isComplete else { return }
            let girths = rec.turn.girths()
            box.lock.lock()
            defer { box.lock.unlock() }
            for (level, i, d) in [(BodyLevel.chest, 1, BodyDimension.chest), (.waist, 2, .waist), (.hip, 3, .hip)] {
                guard let g = girths[level]?.cm else { continue }
                box.t.add("\(p.sex.rawValue) \(d.rawValue) vs body filmed", g - truth[i])
                if let tape = p.tape[d] { box.t.add("\(p.sex.rawValue) \(d.rawValue) vs tape", g - tape) }
            }
            var scan = StationScan()
            for (k, widths) in rec.turn.stations().enumerated() {
                if let widths { scan.record(widths, at: k) }
            }
            LearnedGirthModel.correct(&scan, turn: rec.turn, plain: girths, heightCm: truth[0], weightKg: p.weight, sex: p.sex)
            let production = scan.girths()
            for (level, i, d) in [(BodyLevel.chest, 1, BodyDimension.chest), (.waist, 2, .waist), (.hip, 3, .hip)] {
                guard let g = production[level]?.cm else { continue }
                box.t.add("\(p.sex.rawValue) \(d.rawValue) production scan vs body filmed", g - truth[i])
            }
            let c = LearnedGirthModel.girths(rec.turn, heightCm: truth[0], weightKg: p.weight, sex: p.sex)
            for (level, i, d) in [(BodyLevel.chest, 1, BodyDimension.chest), (.waist, 2, .waist), (.hip, 3, .hip)] {
                guard let g = c[level]?.cm else { continue }
                box.t.add("\(p.sex.rawValue) \(d.rawValue) engine C vs body filmed", g - truth[i])
            }
        }
        return box.t
    }

    static func write(_ report: String) {
        print(report)
        if let path = env["PUBLIC_BODIES_REPORT"] {
            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? (old + report).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    @Test(.enabled(if: env["BDIMS_CSV"] != nil)) func measuredAdults() throws {
        let people = Self.bdims(Self.env["BDIMS_CSV"]!)
        try #require(people.count > 500)
        let model = try #require(SomaModel.shared)
        var report = "# Body Dimensions (Heinz et al. 2003): \(people.filter { $0.sex == .male }.count) men, \(people.filter { $0.sex == .female }.count) women\n\n"
        let est = Self.estimates(people)
        report += est.report("Height/weight estimate minus tape (cm)")
        let (avatar, worst) = Self.avatars(people, model: model)
        report += avatar.report("Avatar built from the tape, measured back minus tape (cm)")
        report += worst.map { "- " + $0 }.joined(separator: "\n") + "\n"
        if Self.env["SCAN_ONLY"] != nil { report = "SCAN_OFF=\(Self.env["SCAN_OFF"] ?? "")\n" }
        let scan = Self.scans(people, model: model)
        report += scan.report("Simulated filmed turn (engine A)")
        Self.write(report)
    }

    @Test(.enabled(if: env["PUBLIC_FIGURES_JSON"] != nil)) func publicFigures() throws {
        let people = Self.figures(Self.env["PUBLIC_FIGURES_JSON"]!)
        try #require(!people.isEmpty)
        let model = try #require(SomaModel.shared)
        var report = "# Public figures: \(people.filter { $0.sex == .male }.count) men, \(people.filter { $0.sex == .female }.count) women\n\n"
        var est = Self.estimates(people)
        // Their waist is the narrowest point, not the navel: shown apart.
        for p in people {
            if let w = p.naturalWaist,
               let e = AnthropometricPrior().estimate(heightCm: p.height, weightKg: p.weight, sex: p.sex)[.waist]?.cm {
                est.add("\(p.sex.rawValue) narrowest waist (navel estimate − listed)", e - w)
            }
        }
        report += est.report("Height/weight estimate minus published (cm)")
        let (avatar, worst) = Self.avatars(people, model: model)
        report += avatar.report("Avatar built from the published figures, measured back minus published (cm)")
        report += worst.map { "- " + $0 }.joined(separator: "\n") + "\n"
        Self.write(report)
    }
}
