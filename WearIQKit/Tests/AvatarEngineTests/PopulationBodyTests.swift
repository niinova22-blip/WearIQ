import Foundation
import Testing
@testable import AvatarEngine
import WearIQCore

/// The avatar is the shopper: across the 400 bodies (`Population`), from a slight 45 kg
/// woman to a 150 kg man, the body the avatar is built from measures as the person does.
/// A shopper who sees a body that isn't theirs stops trusting what the clothes on it show.
@Suite struct PopulationBodyTests {
    @Test func populationCoversPeople() throws {
        let people = Population.shared
        try #require(people.count == 400)
        #expect(people.filter { $0.sex == .male }.count == 200)
        print(Population.describe(people))
        // Every BMI class from under 18.5 to 35+, the old and the young, short and tall.
        for c in Population.Shopper.BMIClass.allCases where c != .under {
            #expect(people.filter { $0.bmiClass == c }.count >= 15, "\(c)")
        }
        #expect(people.contains { $0.age >= 60 })
        for sex in [BodySex.male, .female] {
            for band in ["short", "tall"] {
                #expect(people.filter { $0.sex == sex && $0.heightBand == band }.count >= 15)
            }
        }
        #expect(Set(people.filter { $0.sex == .female }.map(\.shape)).count >= 5)
    }

    /// Built and measured back: girths within 2.5 cm (2% at most bodies), lengths within
    /// 2 cm, for 95% of people; nobody off by more than 3 cm anywhere.
    @Test func avatarMeasuresAsThePerson() throws {
        let model = try #require(SomaModel.shared)
        let people = Population.shared
        try #require(people.count == 400)
        let names = ["height", "chest", "waist", "hip", "thigh", "shoulder", "arm", "inseam"]
        var errors = [[Double]](repeating: [], count: names.count)
        var worst: [(Double, String)] = []
        for s in people {
            let m = s.measurements
            let bust = SomaModel.typicalBust(female: s.sex == .female, chest: m.chest)
            let got = model.measure(model.body(for: m.somaTarget, bust: bust))
            for (i, (want, have)) in zip(m.somaTarget, got).enumerated() {
                errors[i].append(have - want)
                if abs(have - want) > 2.5 {
                    worst.append((abs(have - want), "#\(s.id) \(s.sex) \(s.origin) BMI \(Int(s.bmi)) \(s.shape): \(names[i]) wanted \(String(format: "%.1f", want)) built \(String(format: "%.1f", have))"))
                }
            }
        }
        var report = ""
        for (i, e) in errors.enumerated() {
            let a = e.map(abs).sorted()
            let mae = a.reduce(0, +) / Double(a.count)
            let p95 = a[Int(0.95 * Double(a.count - 1))]
            report += "\(names[i]): MAE \(String(format: "%.2f", mae)) cm, p95 \(String(format: "%.2f", p95)), max \(String(format: "%.2f", a.last!))\n"
            let limit = i == 0 ? 1.0 : (1...4).contains(i) ? 2.5 : 2
            #expect(p95 <= limit, "\(names[i]) p95 \(p95)")
            #expect(a.last! <= 3, "\(names[i]) max \(a.last!)")
        }
        report += worst.sorted { $0.0 > $1.0 }.prefix(15).map(\.1).joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["AUDIT_REPORT"] {
            try report.write(toFile: path + ".body.txt", atomically: true, encoding: .utf8)
        }
    }
}
