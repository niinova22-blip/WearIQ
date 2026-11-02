import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

/// The extra side photo after the turn: asked for only where the turn was unsure, and it
/// brings that girth closer to the tape.
@Suite struct FollowUpShotTests {
    /// Ellipse half-width a (seen from the front) and half-depth b, cm.
    let sections: [BodyLevel: (Double, Double)] = [.chest: (17, 12), .waist: (15, 11), .hip: (18, 13)]

    func width(_ level: BodyLevel, _ station: Int) -> Double {
        let (a, b) = sections[level]!
        let t = Double(station) * .pi / 4
        return 2 * (a * a * cos(t) * cos(t) + b * b * sin(t) * sin(t)).squareRoot()
    }

    func perimeter(_ level: BodyLevel) -> Double {
        let (a, b) = sections[level]!
        let h = (a - b) * (a - b) / ((a + b) * (a + b))
        return .pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
    }

    /// The side stops read 7% wide (the user swayed there), every frame fitted well
    /// except the waist's.
    func scan() -> StationScan {
        var scan = StationScan()
        for k in 0..<StationScan.stationCount {
            var w: [BodyLevel: Double] = [:]
            for level in sections.keys { w[level] = width(level, k) * (k % 4 == 2 ? 1.07 : 1) }
            scan.record(w, at: k)
        }
        for level in [BodyLevel.chest, .hip] {
            scan.everyFrame[level] = MeasuredValue(cm: perimeter(level), uncertaintyCm: 0.01 * perimeter(level), source: .scan)
        }
        scan.everyFrame[.waist] = MeasuredValue(cm: perimeter(.waist) * 1.04, uncertaintyCm: 0.04 * perimeter(.waist), source: .scan)
        return scan
    }

    @Test func asksForTheUnsureLevelOnly() {
        #expect(FollowUpShot.plan(scan()) == FollowUpShot(level: .waist))
        var sure = scan()
        sure.everyFrame[.waist] = MeasuredValue(cm: perimeter(.waist), uncertaintyCm: 0.01 * perimeter(.waist), source: .scan)
        // The stops' side widths disagree with the fit, but by under 3%: nothing to ask.
        #expect(FollowUpShot.plan(sure) == nil)
    }

    @Test func theStillBringsTheGirthCloser() throws {
        var scan = scan()
        let before = try #require(scan.girths()[.waist])
        scan.stills[2] = Dictionary(uniqueKeysWithValues: sections.keys.map { ($0, width($0, 2)) })
        let after = try #require(scan.girths()[.waist])
        let truth = perimeter(.waist)
        #expect(abs(after.cm - truth) < abs(before.cm - truth) / 2, "before \(before.cm) after \(after.cm) tape \(truth)")
        #expect(after.uncertaintyCm < before.uncertaintyCm)
    }
}
