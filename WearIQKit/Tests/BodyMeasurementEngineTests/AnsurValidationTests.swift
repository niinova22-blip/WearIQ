import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

/// Validates the measurement engine against the ANSUR II anthropometric survey (US Army
/// 2012, public domain: https://www.openlab.psu.edu/ansur2/): 4,082 men and 1,986 women
/// measured with tape and calipers.
///
/// For the chest, waist and hips ANSUR lists the breadth (seen from the front), the depth
/// (seen from the side) and the tape circumference. Each cross-section is modelled as the
/// superellipse |x/a|ⁿ + |y/b|ⁿ = 1 with that breadth and depth whose perimeter equals the
/// tape circumference, which covers shapes from rounded to boxy. The guided turn is then
/// simulated on it — eight stops, each turned up to 15° off and read with silhouette noise —
/// and `StationScan` must give back the tape value.
@Suite struct AnsurValidationTests {
    struct Subject {
        var sex: BodySex
        var heightCm: Double
        var weightKg: Double
        var mm: [String: Double]
    }

    static let subjects: [Subject] = {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Data")
        return load(dir.appendingPathComponent("ANSUR_II_MALE_Public.csv"), .male)
            + load(dir.appendingPathComponent("ANSUR_II_FEMALE_Public.csv"), .female)
    }()

    static func load(_ url: URL, _ sex: BodySex) -> [Subject] {
        guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",").map({ $0.lowercased() }) else { return [] }
        return lines.dropFirst().compactMap { line in
            let cells = line.split(separator: ",", omittingEmptySubsequences: false)
            var mm: [String: Double] = [:]
            for (name, cell) in zip(header, cells) { mm[name] = Double(cell) }
            // Stature in mm, weight in tenths of a kilogram.
            guard let stature = mm["stature"], let weight = mm["weightkg"] else { return nil }
            return Subject(sex: sex, heightCm: stature / 10, weightKg: weight / 10, mm: mm)
        }
    }

    /// (breadth, depth, circumference) columns per level.
    static let columns: [BodyLevel: (String, String, String)] = [
        .chest: ("chestbreadth", "chestdepth", "chestcircumference"),
        .waist: ("waistbreadth", "waistdepth", "waistcircumference"),
        .hip: ("hipbreadth", "buttockdepth", "buttockcircumference"),
    ]

    // MARK: Superellipse cross-sections

    struct Section {
        let a, b, n: Double
        static let samples = 360

        func point(_ t: Double) -> (Double, Double) {
            let c = cos(t), s = sin(t)
            return (a * copysign(pow(abs(c), 2 / n), c), b * copysign(pow(abs(s), 2 / n), s))
        }

        var perimeter: Double {
            var sum = 0.0
            var previous = point(0)
            for i in 1...Self.samples {
                let p = point(Double(i) / Double(Self.samples) * 2 * .pi)
                sum += ((p.0 - previous.0) * (p.0 - previous.0) + (p.1 - previous.1) * (p.1 - previous.1)).squareRoot()
                previous = p
            }
            return sum
        }

        /// Silhouette width seen from `degrees` (0 = from the front, along the depth axis).
        func width(degrees: Double) -> Double {
            let t = degrees * .pi / 180
            // Seen from direction (sin t, cos t), the outline spans the axis (cos t, −sin t).
            let projections = (0..<Self.samples).map { i -> Double in
                let p = point(Double(i) / Double(Self.samples) * 2 * .pi)
                return p.0 * cos(t) - p.1 * sin(t)
            }
            return projections.max()! - projections.min()!
        }

        /// The superellipse of this breadth and depth whose perimeter matches the tape.
        static func fitted(breadth: Double, depth: Double, circumference: Double) -> Section? {
            var lo = 1.0, hi = 12.0
            let a = breadth / 2, b = depth / 2
            guard Section(a: a, b: b, n: lo).perimeter <= circumference else { return nil }
            // The chest tape passes over the back muscles, which reach wider than the
            // caliper breadth: then keep the proportions of a rounded box and scale it up.
            if Section(a: a, b: b, n: hi).perimeter < circumference {
                let scale = circumference / Section(a: a, b: b, n: 4).perimeter
                return Section(a: a * scale, b: b * scale, n: 4)
            }
            for _ in 0..<22 {
                let mid = (lo + hi) / 2
                if Section(a: a, b: b, n: mid).perimeter < circumference { lo = mid } else { hi = mid }
            }
            return Section(a: a, b: b, n: (lo + hi) / 2)
        }
    }

    /// Deterministic noise so runs are reproducible.
    struct Noise {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u = max(uniform(), 1e-12), v = uniform()
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
    }

    struct Errors {
        var relative: [Double] = []
        var mean: Double { relative.reduce(0, +) / Double(max(relative.count, 1)) }
        var meanAbsolute: Double { relative.map(abs).reduce(0, +) / Double(max(relative.count, 1)) }
        var p95: Double {
            let sorted = relative.map(abs).sorted()
            return sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        }
    }

    @Test func dataIsPresent() {
        #expect(Self.subjects.count > 6000)
    }

    /// The guided turn against tape circumferences of every ANSUR subject.
    @Test func guidedTurnMatchesTapeCircumferences() throws {
        var noise = Noise(state: 42)
        var errors: [BodyLevel: Errors] = [:]
        var ellipseBaseline: [BodyLevel: Errors] = [:]
        var skipped = 0
        for subject in Self.subjects {
            var scan = StationScan()
            var widths = [[BodyLevel: Double]](repeating: [:], count: StationScan.stationCount)
            var truth: [BodyLevel: Double] = [:]
            for (level, (bCol, dCol, cCol)) in Self.columns {
                guard let breadth = subject.mm[bCol], let depth = subject.mm[dCol], let tape = subject.mm[cCol],
                      let section = Section.fitted(breadth: breadth / 10, depth: depth / 10, circumference: tape / 10)
                else { skipped += 1; continue }
                truth[level] = tape / 10
                for i in 0..<StationScan.stationCount {
                    // Each stop up to 15° off, widths read with 1.5% silhouette noise.
                    let angle = Double(i) * 45 + (noise.uniform() * 30 - 15)
                    widths[i][level] = section.width(degrees: angle) * (1 + 0.015 * noise.gaussian())
                }
                // What the earlier front + side method would give: an ellipse from breadth and depth.
                let ellipse = BodyMeasurementEngine.ellipsePerimeter(a: breadth / 20, b: depth / 20)
                ellipseBaseline[level, default: Errors()].relative.append(ellipse / (tape / 10) - 1)
            }
            for i in 0..<StationScan.stationCount { scan.record(widths[i], at: i) }
            let girths = scan.girths()
            for (level, tape) in truth {
                guard let measured = girths[level] else { continue }
                errors[level, default: Errors()].relative.append(measured.cm / tape - 1)
            }
        }

        print("ANSUR II validation, \(Self.subjects.count) subjects (\(skipped) sections without data):")
        for level in [BodyLevel.chest, .waist, .hip] {
            let e = try #require(errors[level])
            let base = try #require(ellipseBaseline[level])
            print(String(format: "  %@: n=%d  bias %+.2f%%  mean |error| %.2f%%  95th pct %.2f%%   (ellipse from breadth+depth: bias %+.2f%%, 95th %.2f%%)",
                         level.rawValue, e.relative.count, e.mean * 100, e.meanAbsolute * 100, e.p95 * 100,
                         base.mean * 100, base.p95 * 100))
            #expect(e.relative.count > 5000, "\(level)")
            #expect(abs(e.mean) < 0.005, "\(level) bias \(e.mean)")
            #expect(e.p95 < 0.04, "\(level) p95 \(e.p95)")
        }
    }

    /// Stature from the skeleton alone: joints placed at each subject's ANSUR landmark
    /// heights (with 1 cm detection noise) must give back their stature.
    @Test func skeletonGivesStature() {
        var noise = Noise(state: 3)
        var errors = Errors()
        for s in Self.subjects {
            func h(_ key: String) -> Double? { s.mm[key].map { $0 / 10 } }
            guard let ankle = h("lateralmalleolusheight"), let knee = h("lateralfemoralepicondyleheight"),
                  let troch = h("trochanterionheight"), let acromion = h("acromialheight"),
                  let sternum = h("suprasternaleheight") else { continue }
            // Joint centres relative to the surface landmarks: hip joint a little above the
            // trochanter, shoulder joint centre about 2% of stature below the acromion.
            let heights: [BodyJoint: Double] = [
                .leftAnkle: ankle, .rightAnkle: ankle, .leftKnee: knee, .rightKnee: knee,
                .leftHip: troch + 0.007 * s.heightCm, .rightHip: troch + 0.007 * s.heightCm,
                .leftShoulder: acromion - 0.02 * s.heightCm, .rightShoulder: acromion - 0.02 * s.heightCm,
                .neck: sternum,
            ]
            // Image rows at 10 px per cm, floor at row 3000.
            let joints = heights.mapValues { Point2D(0, 3000 - 10 * ($0 + noise.gaussian())) }
            guard let fit = JointHeights.fit(joints) else { continue }
            errors.relative.append(fit.staturePx / 10 / s.heightCm - 1)
        }
        print(String(format: "Skeleton stature: n=%d  bias %+.2f%%  mean |error| %.2f%%  95th pct %.2f%%",
                     errors.relative.count, errors.mean * 100, errors.meanAbsolute * 100, errors.p95 * 100))
        #expect(errors.relative.count > 6000)
        #expect(abs(errors.mean) < 0.01)
        #expect(errors.p95 < 0.04)
    }

    /// The waist and hip estimates on US civilians (NHANES 2017–March 2020, 6,456 adults),
    /// and how often the plausibility check would reject a correct civilian reading.
    @Test func estimatesHoldForCivilians() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Data/NHANES_2017_2020_adults.csv")
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst()
        var noise = Noise(state: 11)
        var errors: [BodyDimension: Errors] = [:]
        var rejected: [BodyDimension: Int] = [:]
        var waistWithoutAge = Errors()
        var count = 0
        for line in lines {
            let c = line.split(separator: ",")
            guard c.count >= 6, let h = Double(c[1]), let w = Double(c[2]), let waist = Double(c[3]), let hip = Double(c[4]),
                  let age = Double(c[5]) else { continue }
            let sex: BodySex = c[0] == "male" ? .male : .female
            let prior = AnthropometricPrior().estimate(heightCm: h, weightKg: w, sex: sex, ageYears: age)
            if let noAge = AnthropometricPrior().estimate(heightCm: h, weightKg: w, sex: sex)[.waist] {
                waistWithoutAge.relative.append(noAge.cm / waist - 1)
            }
            count += 1
            var scan = BodyProfile()
            for (d, truth) in [(BodyDimension.waist, waist), (.hip, hip)] {
                errors[d, default: Errors()].relative.append(try #require(prior[d]).cm / truth - 1)
                scan[d] = MeasuredValue(cm: truth * (1 + 0.03 * noise.gaussian()), uncertaintyCm: 0.03 * truth, source: .scan)
            }
            for d in MeasurementFusion.fuse(scan: scan, prior: prior).rejected { rejected[d, default: 0] += 1 }
        }
        print("NHANES civilians, n=\(count):")
        print(String(format: "  waist without age: bias %+.2f%%  mean |error| %.2f%%", waistWithoutAge.mean * 100, waistWithoutAge.meanAbsolute * 100))
        for d in [BodyDimension.waist, .hip] {
            let e = try #require(errors[d])
            let rate = Double(rejected[d] ?? 0) / Double(count)
            print(String(format: "  %@ estimate: bias %+.2f%%  mean |error| %.2f%%;  correct readings rejected %.2f%%",
                         d.rawValue, e.mean * 100, e.meanAbsolute * 100, rate * 100))
            #expect(abs(e.mean) < 0.02, "\(d)")
            if d == .waist { #expect(e.meanAbsolute < waistWithoutAge.meanAbsolute, "age helps the waist") }
            #expect(rate < 0.02, "\(d) rejects \(rate)")
        }
    }

    /// How often the height/weight check would throw away a correct reading. A scan
    /// reading with 3% error should almost never be rejected for a real body.
    @Test func plausibilityCheckRarelyRejectsRealBodies() {
        var noise = Noise(state: 7)
        var checked: [BodyDimension: Int] = [:]
        var rejected: [BodyDimension: Int] = [:]
        for s in Self.subjects {
            let m = s.mm
            func cm(_ key: String) -> Double? { m[key].map { $0 / 10 } }
            var truth: [BodyDimension: Double] = [:]
            truth[.chest] = cm("chestcircumference")
            truth[.waist] = cm("waistcircumference")
            truth[.hip] = cm("buttockcircumference")
            truth[.thigh] = cm("thighcircumference")
            truth[.shoulderWidth] = cm("biacromialbreadth")
            if let upper = cm("acromionradialelength"), let lower = cm("radialestylionlength") { truth[.armLength] = upper + lower }
            if let neck = cm("cervicaleheight"), let navel = cm("waistheightomphalion") { truth[.torsoLength] = neck - navel }
            truth[.inseam] = cm("crotchheight")
            truth[.outseam] = cm("waistheightomphalion")

            var scan = BodyProfile()
            for (d, v) in truth {
                scan[d] = MeasuredValue(cm: v * (1 + 0.03 * noise.gaussian()), uncertaintyCm: 0.03 * v, source: .scan)
            }
            let prior = AnthropometricPrior().estimate(heightCm: s.heightCm, weightKg: s.weightKg, sex: s.sex)
            let result = MeasurementFusion.fuse(scan: scan, prior: prior)
            for d in truth.keys { checked[d, default: 0] += 1 }
            for d in result.rejected { rejected[d, default: 0] += 1 }
        }
        print("Plausibility check, share of correct (±3%) readings rejected:")
        for d in checked.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let rate = Double(rejected[d] ?? 0) / Double(checked[d] ?? 1)
            print(String(format: "  %@: %.2f%%", d.rawValue, rate * 100))
            #expect(rate < 0.02, "\(d) rejects \(rate)")
        }
    }
}
