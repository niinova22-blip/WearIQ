import BodyMeasurementEngine
import Foundation
@testable import AvatarEngine
import WearIQCore

/// Four hundred shoppers, 200 men and 200 women, chosen to cover people as they are and
/// not as a size chart pictures them:
///
/// - 120 of each sex from ANSUR II (US Army, 2012; tape-measured; public domain,
///   https://www.openlab.psu.edu/ansur2/): every girth and length measured. Chosen at
///   even steps of BMI, of stature and of hip-minus-chest, so the slight, the heavy, the
///   short, the tall, the pear- and the broad-shouldered are all there.
/// - 80 of each sex from NHANES 2017–2020 (US civilians, CDC; public domain): older and
///   heavier than soldiers (BMI to 60+), the bodies most charts stop short of. NHANES
///   measures height, weight, waist and hip; the other girths and lengths are the ANSUR
///   relations' estimate given those (`AnthropometricPrior`, `GirthCorrelations`).
///
/// Each shopper's body is known three ways, as in the app: tape-measured (±1 cm),
/// scanned (±2.5 cm, shoulders bone to bone) and only estimated from height, weight and
/// age (the app before a scan). `truth` is the body itself.
struct Population {
    enum Origin: String { case ansur = "ANSUR", nhanes = "NHANES" }
    enum Mode: String, CaseIterable { case tape, scan, estimate }

    struct Shopper {
        var id: Int
        var sex: BodySex
        var origin: Origin
        var age: Int
        var weightKg: Double
        var truth: [BodyDimension: Double]
        var scanned: Bool

        var height: Double { truth[.height]! }
        var bmi: Double { weightKg / (height / 100 * height / 100) }

        /// The body as the app knows it.
        func body(_ mode: Mode) -> BodyProfile {
            var values: [BodyDimension: MeasuredValue] = [.height: MeasuredValue(cm: height, uncertaintyCm: 0.5, source: .userProvided)]
            switch mode {
            case .tape, .scan:
                let scan = mode == .scan
                let u: [BodyDimension: (Double, Double)] = [
                    .chest: (1, 2.5), .waist: (1, 2.5), .hip: (1, 2.5), .thigh: (1, 2.5), .shoulderWidth: (1, 1.5),
                    .armLength: (1, 2), .torsoLength: (1.5, 2.5), .inseam: (1, 2),
                ]
                for (d, (tape, sc)) in u.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    guard let x = truth[d] else { continue }
                    // A scan reports biacromial breadth (bone to bone); a tape goes over the back.
                    var cm = d == .shoulderWidth && !scan ? x * 1.085 : x
                    // A scan is off by its stated error (normal, the same draw on every run);
                    // the tape is taken as the reference.
                    if scan { cm += sc * Self.normal(seed: UInt64(id) &* 31 &+ UInt64(Self.order(d))) }
                    values[d] = MeasuredValue(cm: cm, uncertaintyCm: scan ? sc : tape, source: scan ? .scan : .manual)
                }
            case .estimate:
                for (d, v) in AnthropometricPrior().estimate(heightCm: height, weightKg: weightKg, sex: sex, ageYears: Double(age)) {
                    values[d] = v
                }
            }
            var p = BodyProfile(values: values)
            p.sex = sex
            p.weightKg = weightKg
            return p
        }

        static func order(_ d: BodyDimension) -> Int { BodyDimension.allCases.firstIndex(of: d) ?? 0 }

        /// A standard normal draw from a seed (SplitMix64, Box–Muller).
        static func normal(seed: UInt64) -> Double {
            var state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678
            func next() -> Double {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
            }
            let u1 = max(next(), 1e-12), u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }

        /// The avatar's measurements: the body itself.
        var measurements: Avatar.Measurements {
            Avatar.Measurements(height: height, chest: truth[.chest]!, waist: truth[.waist]!, hip: truth[.hip]!,
                                thigh: truth[.thigh]!, shoulderWidth: truth[.shoulderWidth]!, armLength: truth[.armLength]!,
                                inseam: truth[.inseam]!, sex: sex)
        }

        // MARK: Who they are

        enum BMIClass: String, CaseIterable { case under = "<18.5", normal = "18.5–25", over = "25–30", obese = "30–35", severe = "35+" }
        var bmiClass: BMIClass {
            switch bmi {
            case ..<18.5: .under
            case ..<25: .normal
            case ..<30: .over
            case ..<35: .obese
            default: .severe
            }
        }

        var heightBand: String {
            let (short, tall): (Double, Double) = sex == .male ? (168, 184) : (157, 170)
            return height < short ? "short" : height > tall ? "tall" : "average height"
        }

        var ageBand: String { age < 30 ? "18–29" : age < 45 ? "30–44" : age < 60 ? "45–59" : "60+" }

        /// Body shape from bust (chest), waist and hip: FFIT (Lee, Istook et al. 2007),
        /// without the high hip, its spoon folded into bottom hourglass. For men, the
        /// shapes menswear is cut around.
        var shape: String {
            let b = truth[.chest]! / 2.54, w = truth[.waist]! / 2.54, h = truth[.hip]! / 2.54
            if sex == .male {
                if w >= truth[.chest]! / 2.54 - 1 { return "oval (waist ≥ chest)" }
                if b - w >= 8 { return "inverted triangle" }
                if h - b >= 1.5 { return "triangle" }
                return "rectangle"
            }
            if b - h <= 1, h - b < 3.6, b - w >= 9 || h - w >= 10 { return "hourglass" }
            if h - b >= 3.6, h - b < 10, h - w >= 9 { return "bottom hourglass / spoon" }
            if b - h > 1, b - h < 10, b - w >= 9 { return "top hourglass" }
            if h - b >= 3.6, h - w < 9 { return "triangle (pear)" }
            if b - h >= 3.6, b - w < 9 { return "inverted triangle" }
            if w >= b, w >= h - 2 { return "oval (apple)" }
            return "rectangle"
        }
    }

    // MARK: Data

    static func csv(_ file: String) -> [[String: String]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../BodyMeasurementEngineTests/Data/\(file)")
        guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",").map({ $0.lowercased() }) else { return [] }
        return lines.dropFirst().map { line in
            Dictionary(zip(header, line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)),
                       uniquingKeysWith: { a, _ in a })
        }
    }

    /// `count` rows at even steps of each key in turn, without repeats.
    static func spread<T>(_ rows: [T], count: Int, keys: [(T) -> Double]) -> [Int] {
        var chosen: [Int] = [], seen = Set<Int>()
        let per = count / keys.count
        for (k, key) in keys.enumerated() {
            let order = rows.indices.sorted { key(rows[$0]) < key(rows[$1]) }
            let n = k == keys.count - 1 ? count - chosen.count : per
            for j in 0..<n {
                // Both ends included: the very lightest and heaviest are the point.
                var i = Int((Double(j) / Double(max(1, n - 1)) * Double(order.count - 1)).rounded())
                while seen.contains(order[i]) { i = (i + 1) % order.count }
                seen.insert(order[i])
                chosen.append(order[i])
            }
        }
        return chosen
    }

    static let shared = make()

    static func make() -> [Shopper] {
        var out: [Shopper] = []
        for sex in [BodySex.male, .female] {
            let rows = csv(sex == .male ? "ANSUR_II_MALE_Public.csv" : "ANSUR_II_FEMALE_Public.csv")
            guard !rows.isEmpty else { return [] }
            func d(_ r: [String: String], _ k: String) -> Double { Double(r[k] ?? "") ?? 0 }
            let bmi = { (r: [String: String]) in d(r, "weightkg") / 10 / pow(d(r, "stature") / 1000, 2) }
            let picks = spread(rows, count: 120, keys: [bmi, { d($0, "stature") },
                                                        { d($0, "buttockcircumference") - d($0, "chestcircumference") }])
            for (n, i) in picks.enumerated() {
                let r = rows[i]
                func cm(_ k: String) -> Double { d(r, k) / 10 }
                out.append(Shopper(
                    id: out.count, sex: sex, origin: .ansur, age: Int(d(r, "age")), weightKg: d(r, "weightkg") / 10,
                    truth: [
                        .height: cm("stature"), .chest: cm("chestcircumference"), .waist: cm("waistcircumference"),
                        .hip: cm("buttockcircumference"), .thigh: cm("thighcircumference"),
                        .shoulderWidth: cm("biacromialbreadth"),
                        .armLength: cm("acromionradialelength") + cm("radialestylionlength"),
                        .torsoLength: cm("cervicaleheight") - cm("waistheightomphalion"), .inseam: cm("crotchheight"),
                    ],
                    scanned: n % 2 == 1))
            }
        }
        let nhanes = csv("NHANES_2017_2020_adults.csv")
        guard !nhanes.isEmpty else { return [] }
        for sex in [BodySex.male, .female] {
            let rows = nhanes.filter { $0["sex"] == (sex == .male ? "male" : "female") }
            func d(_ r: [String: String], _ k: String) -> Double { Double(r[k] ?? "") ?? 0 }
            let picks = spread(rows, count: 80, keys: [{ d($0, "weight") / pow(d($0, "height") / 100, 2) },
                                                       { d($0, "age") }, { d($0, "height") },
                                                       { d($0, "hip") - d($0, "waist") }])
            for (n, i) in picks.enumerated() {
                let r = rows[i]
                let h = d(r, "height"), w = d(r, "weight"), age = d(r, "age")
                let prior = AnthropometricPrior().estimate(heightCm: h, weightKg: w, sex: sex, ageYears: age)
                let observed: [BodyDimension: MeasuredValue] = [
                    .waist: MeasuredValue(cm: d(r, "waist"), uncertaintyCm: 1, source: .manual),
                    .hip: MeasuredValue(cm: d(r, "hip"), uncertaintyCm: 1, source: .manual),
                ]
                let girths = AnthropometricPrior.conditioned([.chest, .thigh], estimates: prior, observed: observed, sex: sex)
                var truth: [BodyDimension: Double] = [.height: h, .waist: d(r, "waist"), .hip: d(r, "hip")]
                for dim in [BodyDimension.chest, .thigh, .shoulderWidth, .armLength, .torsoLength, .inseam] {
                    truth[dim] = girths[dim]?.cm ?? prior[dim]?.cm
                }
                guard truth.count == 9, truth.values.allSatisfy({ $0 > 0 }) else { continue }
                out.append(Shopper(id: out.count, sex: sex, origin: .nhanes, age: Int(age), weightKg: w, truth: truth,
                                   scanned: n % 2 == 1))
            }
        }
        return out
    }

    /// Counts by group, for the report.
    static func describe(_ shoppers: [Shopper]) -> String {
        func tally(_ key: (Shopper) -> String) -> String {
            Dictionary(grouping: shoppers, by: key).map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ")
        }
        return """
        sex: \(tally { $0.sex.rawValue }); source: \(tally { $0.origin.rawValue })
        BMI: \(tally { $0.bmiClass.rawValue })
        age: \(tally { $0.ageBand }); height: \(tally { "\($0.sex.rawValue) \($0.heightBand)" })
        shape: \(tally { "\($0.sex.rawValue) \($0.shape)" })
        """
    }
}
