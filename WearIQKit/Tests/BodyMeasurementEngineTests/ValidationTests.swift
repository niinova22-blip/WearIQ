import Foundation
import Testing
import WearIQCore
@testable import BodyMeasurementEngine

/// The validation bookkeeping, on made-up records (marked synthetic where they would
/// otherwise count).
@Suite struct ValidationTests {
    func record(_ person: String, tape: Double, a: Double, b: Double, synthetic: Bool = false) -> ValidationRecord {
        var r = ValidationRecord(participant: person, device: "iPhone12,1", hasLiDAR: false, clothing: "underwear",
                                 sex: .male, heightCm: 175, weightKg: 72)
        r.isSynthetic = synthetic
        r.setTape(.waist, tape)
        r.set(.current, [.waist: EngineMeasurement(cm: a, sdCm: 2, provenance: .observed)])
        r.set(.silhouetteFit, [.waist: EngineMeasurement(cm: b, sdCm: 1.5, provenance: .observed)])
        return r
    }

    @Test func statistics() throws {
        let records = [record("P1", tape: 80, a: 83, b: 81), record("P2", tape: 90, a: 88, b: 90.5),
                       record("P1", tape: 80, a: 84, b: 80.5)]
        let report = ValidationReport(records)
        let a = try #require(report.stats[.current]?[.waist])
        #expect(a.n == 3 && abs(a.meanAbsoluteError - 3) < 1e-9 && abs(a.bias - (3 - 2 + 4) / 3) < 1e-9)
        #expect(a.medianAbsoluteError == 3 && a.maxAbsoluteError == 4)
        let b = try #require(report.stats[.silhouetteFit]?[.waist])
        #expect(abs(b.meanAbsoluteError - (1 + 0.5 + 0.5) / 3) < 1e-9)
        // P1 scanned twice: A read 83 and 84, B 81 and 80.5.
        #expect(abs((report.repeatability[.current]?[.waist] ?? 0) - 0.5.squareRoot()) < 1e-9)
        #expect(report.participants == 2 && report.records == 3)
    }

    @Test func syntheticRecordsNeverCount() {
        let report = ValidationReport([record("S1", tape: 80, a: 90, b: 80, synthetic: true)])
        #expect(report.records == 0 && report.syntheticLeftOut == 1 && report.stats.isEmpty)
        let many = (0..<30).map { record("S\($0)", tape: 80, a: 85, b: 80, synthetic: true) }
        #expect(EngineSelection.decide(.waist, records: many) == .undecided(participants: 0, needed: 20))
    }

    @Test func decidesOnlyWithEnoughClearEvidence() {
        // Too few people: undecided whatever the numbers, and production keeps A.
        let few = (0..<10).map { record("P\($0)", tape: 80, a: 84, b: 80.5) }
        #expect(EngineSelection.decide(.waist, records: few).engine == .current)
        // 24 people, B clearly closer.
        let better = (0..<24).map { i in record("P\(i)", tape: 80, a: 80 + 3 + Double(i % 3), b: 80 + Double(i % 2)) }
        if case .useSilhouetteFit = EngineSelection.decide(.waist, records: better) {} else { Issue.record("B should win") }
        // 24 people, A clearly closer.
        let worse = (0..<24).map { i in record("P\(i)", tape: 80, a: 80.5, b: 84 + Double(i % 3)) }
        if case .keepCurrent = EngineSelection.decide(.waist, records: worse) {} else { Issue.record("A should stay") }
        // 24 people, no real difference: undecided, A stays.
        let same = (0..<24).map { i in record("P\(i)", tape: 80, a: i % 2 == 0 ? 81 : 79, b: i % 2 == 0 ? 79 : 81) }
        #expect(EngineSelection.decide(.waist, records: same).engine == .current)
    }

    @Test func failuresAndCSV() {
        var failed = ValidationRecord(participant: "P3", device: "iPhone12,1", hasLiDAR: false, clothing: "fitted",
                                      sex: nil, heightCm: 168, weightKg: nil)
        failed.set(.current, [.waist: EngineMeasurement(cm: 75, sdCm: 2, provenance: .observed)])
        failed.failedEngines = [MeasurementEngineID.silhouetteFit.rawValue]
        let report = ValidationReport([failed, record("P1", tape: 80, a: 82, b: 81)])
        #expect(report.failureRate[.silhouetteFit] == 0.5 && report.failureRate[.current] == 0)
        let csv = ValidationRecord.csv([record("P\"1", tape: 80, a: 82, b: 81)])
        #expect(csv.hasPrefix("participant,date,synthetic"))
        #expect(csv.contains("\"P\"\"1\"") && csv.contains("waist,80.0,82.0"))
    }

    @Test func roundTrips() throws {
        var r = record("P1", tape: 80, a: 82, b: 81)
        r.profiles = [StopProfile(station: 0, torso: [30, nil, 31], legs: [[15, 15.5]], legsOuter: [36])]
        let back = try JSONDecoder().decode(ValidationRecord.self, from: JSONEncoder().encode(r))
        #expect(back == r)
    }

    @Test func profileMedian() {
        let a = StopProfile(station: 2, torso: [30, 40], legs: [[15, 16]], legsOuter: [35])
        let b = StopProfile(station: 2, torso: [32, nil], legs: [[17, 18]], legsOuter: [37])
        let c = StopProfile(station: 2, torso: [31, 42], legs: [[]], legsOuter: [nil])
        let m = StopProfile.median([a, b, c])
        #expect(m?.torso == [31, 42] && m?.legsOuter == [37] && m?.legs == [[17, 18]])
    }
}
