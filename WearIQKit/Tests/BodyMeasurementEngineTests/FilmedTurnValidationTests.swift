import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

/// The filmed ten-second turn on ANSUR II cross-sections: eight directions picked from
/// the recording (the stop-based method) against every frame fitted at once.
///
/// Simulated as a phone sees it: 10 frames a second over 8–12 s, turning unevenly
/// (faster through part of the turn), standing still at the start and coming to rest
/// facing the phone at the end; arm span read with noise; widths with 2% mask noise and
/// one frame in twenty widened by 5–15% (an arm touching, a blurred step).
@Suite struct FilmedTurnValidationTests {
    typealias Section = AnsurValidationTests.Section

    struct Table {
        let widths: [Double]  // every 2°, 0..<180
        init(_ s: Section) { widths = (0..<90).map { s.width(degrees: Double($0) * 2) } }
        func width(_ degrees: Double) -> Double {
            let d = (degrees.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180) / 2
            let i = Int(d), f = d - Double(i)
            return widths[i % 90] * (1 - f) + widths[(i + 1) % 90] * f
        }
    }

    static func simulate(_ tables: [BodyLevel: Table], noise: inout AnsurValidationTests.Noise,
                         widthNoise: Double = 0.02, outliers: Double = 0.05) -> TurnRecording {
        var rec = TurnRecording()
        let duration = 8 + 4 * noise.uniform()
        let wobble = 0.12 * noise.uniform()
        let phase = noise.uniform() * 2 * .pi
        let still = 0.3 + 0.6 * noise.uniform(), rest = 0.8
        let fps = 10.0
        var t = 0.0
        while t <= still + duration + rest {
            let u = min(1, max(0, (t - still) / duration))
            let degrees = 360 * (u + wobble * sin(2 * .pi * u + phase) * sin(.pi * u) / (2 * .pi))
            let theta = degrees * .pi / 180
            let span = max(0.27, abs(cos(theta))) + 0.03 * noise.gaussian()
            var widths: [BodyLevel: Double] = [:]
            for (level, table) in tables {
                var w = table.width(degrees) * (1 + widthNoise * noise.gaussian())
                if noise.uniform() < outliers { w *= 1.05 + 0.1 * noise.uniform() }
                widths[level] = w
            }
            rec.add(.init(time: t, spanRatio: span, widths: widths))
            t += 1 / fps
        }
        return rec
    }

    @Test func everyFrameBeatsEightDirections() throws {
        var noise = AnsurValidationTests.Noise(state: 2026)
        var stations: [BodyLevel: AnsurValidationTests.Errors] = [:]
        var dense: [BodyLevel: AnsurValidationTests.Errors] = [:]
        var incomplete = 0
        for (n, subject) in AnsurValidationTests.subjects.enumerated() where n % 3 == 0 {
            var tables: [BodyLevel: Table] = [:]
            var truth: [BodyLevel: Double] = [:]
            for (level, (bCol, dCol, cCol)) in AnsurValidationTests.columns {
                guard let breadth = subject.mm[bCol], let depth = subject.mm[dCol], let tape = subject.mm[cCol],
                      let section = Section.fitted(breadth: breadth / 10, depth: depth / 10, circumference: tape / 10) else { continue }
                tables[level] = Table(section)
                truth[level] = tape / 10
            }
            let rec = Self.simulate(tables, noise: &noise)
            guard rec.isComplete else { incomplete += 1; continue }
            var scan = StationScan()
            for (k, widths) in rec.stations().enumerated() { if let widths { scan.record(widths, at: k) } }
            let a = scan.girths(), b = rec.girths()
            for (level, tape) in truth {
                if let v = a[level] { stations[level, default: .init()].relative.append(v.cm / tape - 1) }
                if let v = b[level] { dense[level, default: .init()].relative.append(v.cm / tape - 1) }
            }
        }
        print("Filmed turn on ANSUR II (every third subject; \(incomplete) turns not recognised):")
        for level in [BodyLevel.chest, .waist, .hip] {
            let a = try #require(stations[level]), b = try #require(dense[level])
            print(String(format: "  %@: eight directions bias %+.2f%% MAE %.2f%% p95 %.2f%%  |  every frame n=%d bias %+.3f%% MAE %.2f%% p95 %.2f%%",
                         level.rawValue, a.mean * 100, a.meanAbsolute * 100, a.p95 * 100,
                         b.relative.count, b.mean * 100, b.meanAbsolute * 100, b.p95 * 100))
            #expect(b.relative.count >= a.relative.count - 5)
            #expect(b.meanAbsolute < a.meanAbsolute)
            #expect(abs(b.mean) < 0.002)
        }
    }

    /// A poor recording: 4% mask noise and one frame in five widened by 5–15%. Every
    /// frame still does better: the widened frames that stand out are set aside (those
    /// within the noise can't be told apart, so some bias remains, less than the stops').
    @Test func poorRecording() throws {
        var noise = AnsurValidationTests.Noise(state: 7)
        var stations: [BodyLevel: AnsurValidationTests.Errors] = [:]
        var dense: [BodyLevel: AnsurValidationTests.Errors] = [:]
        for (n, subject) in AnsurValidationTests.subjects.enumerated() where n % 12 == 0 {
            var tables: [BodyLevel: Table] = [:]
            var truth: [BodyLevel: Double] = [:]
            for (level, (bCol, dCol, cCol)) in AnsurValidationTests.columns {
                guard let breadth = subject.mm[bCol], let depth = subject.mm[dCol], let tape = subject.mm[cCol],
                      let section = Section.fitted(breadth: breadth / 10, depth: depth / 10, circumference: tape / 10) else { continue }
                tables[level] = Table(section)
                truth[level] = tape / 10
            }
            let rec = Self.simulate(tables, noise: &noise, widthNoise: 0.04, outliers: 0.2)
            guard rec.isComplete else { continue }
            var scan = StationScan()
            for (k, widths) in rec.stations().enumerated() { if let widths { scan.record(widths, at: k) } }
            let a = scan.girths(), b = rec.girths()
            for (level, tape) in truth {
                if let v = a[level] { stations[level, default: .init()].relative.append(v.cm / tape - 1) }
                if let v = b[level] { dense[level, default: .init()].relative.append(v.cm / tape - 1) }
            }
        }
        for level in [BodyLevel.chest, .waist, .hip] {
            let a = try #require(stations[level]), b = try #require(dense[level])
            print(String(format: "  poor %@: eight directions bias %+.2f%% MAE %.2f%%  |  every frame bias %+.2f%% MAE %.2f%%",
                         level.rawValue, a.mean * 100, a.meanAbsolute * 100, b.mean * 100, b.meanAbsolute * 100))
            #expect(b.meanAbsolute < a.meanAbsolute)
            #expect(abs(b.mean) < abs(a.mean))
        }
    }
}
