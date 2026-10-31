import Foundation
import Testing
import WearIQCore
@testable import BodyMeasurementEngine

/// The arithmetic of comparing two measuring systems on the same people. The numbers
/// here are made up to test the sums; they say nothing about either system.
@Suite struct ScanComparisonTests {
    /// Deterministic noise in -1...1.
    func noise(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i * 7919 + salt * 104_729)) * 43_758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }

    func people(_ n: Int, firstError: Double, secondError: Double) -> [ScanValidation.Record] {
        (0..<n).flatMap { i -> [ScanValidation.Record] in
            let tape = 85 + Double(i % 20)
            return [
                .init(subject: "p\(i)", group: "tshirt", dimension: .waist, scanned: tape + firstError * noise(i, 1), tape: tape, system: "current"),
                .init(subject: "p\(i)", group: "tshirt", dimension: .waist, scanned: tape + secondError * noise(i, 2), tape: tape, system: "bodym"),
            ]
        }
    }

    @Test func noWinnerWithFewPeople() {
        let result = ScanValidation.compare(people(12, firstError: 6, secondError: 1), first: "current", second: "bodym")
        let c = result[.init(group: "tshirt", dimension: .waist, system: "")]!
        #expect(c.people == 12)
        #expect(c.verdict == .notEnoughPeople(have: 12, need: 30))
        #expect(c.blendWeight == nil)
    }

    @Test func clearDifferenceNamesTheBetterOne() {
        let result = ScanValidation.compare(people(40, firstError: 6, secondError: 1), first: "current", second: "bodym")
        let c = result[.init(group: "tshirt", dimension: .waist, system: "")]!
        #expect(c.verdict == .secondBetter)
        #expect(c.firstMAE > c.secondMAE)
        // Most of the blend goes to the more accurate one.
        #expect(c.blendWeight! < 0.2)
    }

    @Test func equalSystemsAreNotSeparated() {
        let result = ScanValidation.compare(people(40, firstError: 3, secondError: 3), first: "current", second: "bodym")
        let c = result[.init(group: "tshirt", dimension: .waist, system: "")]!
        #expect(c.verdict == .noClearDifference)
    }

    @Test func scoresPerSystemAndReadsTheColumn() {
        let csv = """
        subject,group,dimension,scanned,low,high,tape,system
        a,skin,chest,96,,,95,current
        a,skin,chest,99,,,95,bodym
        b,skin,chest,90,,,92,current
        """
        let records = ScanValidation.records(csv: csv)
        #expect(records.count == 3)
        let scores = ScanValidation.score(records)
        let current = scores[.init(group: "skin", dimension: .chest, system: "current")]!
        #expect(abs(current.meanAbsoluteError - 1.5) < 1e-9)
        #expect(abs(current.medianAbsoluteError - 1.5) < 1e-9)
        #expect(scores[.init(group: "skin", dimension: .chest, system: "bodym")]!.meanAbsoluteError == 4)
    }
}
