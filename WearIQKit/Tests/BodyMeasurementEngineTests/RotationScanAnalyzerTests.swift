import Foundation
import Testing
@testable import BodyMeasurementEngine
import WearIQCore

/// A synthetic person turning in front of the camera: 1 px = 0.1 cm, 180 cm tall.
/// Torso levels are ellipses; each frame's silhouette width at a level is the ellipse's
/// projected width at that rotation angle.
@Suite struct RotationScanAnalyzerTests {
    private let heightCm = 180.0
    private let pxPerCm = 10.0
    // (fraction of height from the top, half width cm, half depth cm)
    private let levels: [BodyLevel: (Double, Double, Double)] = [
        .chest: (0.28, 17.0, 12.0),   // chest ≈ 92 cm around
        .waist: (0.40, 15.0, 11.0),   // waist ≈ 82 cm
        .hip: (0.50, 18.0, 13.0),     // hip ≈ 98 cm
    ]

    private func ellipsePerimeter(_ a: Double, _ b: Double) -> Double {
        let h = (a - b) * (a - b) / ((a + b) * (a + b))
        return Double.pi * (a + b) * (1 + 3 * h / (10 + (4 - 3 * h).squareRoot()))
    }

    private func frame(angle: Double, scale: Double = 1, armAtChest: Bool = false, t: Double, withAxis: Bool = false) -> RotationFrame {
        let heightPx = Int(heightCm * pxPerCm * scale)
        let width = 800, height = heightPx + 100, top = 40
        var bits = [Bool](repeating: false, count: width * height)
        func fill(_ y: Int, _ halfWidthCm: Double) {
            let half = Int((halfWidthCm * pxPerCm * scale).rounded())
            for x in (width / 2 - half)..<(width / 2 + half) { bits[y * width + x] = true }
        }
        for y in top..<(top + heightPx) {
            let f = Double(y - top) / Double(heightPx)
            // Interpolate cross-sections between the defined levels; head and legs narrower.
            let (a, b): (Double, Double)
            switch f {
            case ..<0.13: (a, b) = (8, 9)
            case ..<0.18: (a, b) = (6, 6)
            default:
                let sorted = levels.values.sorted { $0.0 < $1.0 }
                if let i = sorted.lastIndex(where: { $0.0 <= f }) {
                    let lo = sorted[i], hi = sorted[min(i + 1, sorted.count - 1)]
                    let t = hi.0 > lo.0 ? (f - lo.0) / (hi.0 - lo.0) : 0
                    (a, b) = (lo.1 + (hi.1 - lo.1) * min(1, t), lo.2 + (hi.2 - lo.2) * min(1, t))
                } else {
                    (a, b) = (sorted[0].1, sorted[0].2)
                }
            }
            var halfWidth = (a * a * cos(angle) * cos(angle) + b * b * sin(angle) * sin(angle)).squareRoot()
            if armAtChest, abs(f - 0.28) < 0.02 { halfWidth += 9 }  // arm against the body
            fill(y, halfWidth)
        }
        let axis = atan2(abs(sin(angle)), abs(cos(angle))) * 180 / .pi
        return RotationFrame(mask: BinaryMask(width: width, height: height, bits: bits), centerX: Double(width / 2), time: t,
                             axisAngle: withAxis ? axis : nil)
    }

    private var fractions: [BodyLevel: Double] { levels.mapValues(\.0) }

    @Test func fullTurnGivesTapeGirths() throws {
        let frames = (0..<60).map { i in frame(angle: Double(i) / 60 * 2 * .pi, t: Double(i) / 5) }
        let girths = try RotationScanAnalyzer().girths(frames: frames, heightCm: heightCm, levelFractions: fractions)
        for (level, (_, a, b)) in levels {
            let expected = ellipsePerimeter(a, b)
            let measured = try #require(girths[level]).cm
            #expect(abs(measured - expected) / expected < 0.015, "\(level): \(measured) vs \(expected)")
        }
    }

    @Test func distanceChangesDuringTheTurnDontMatter() throws {
        let frames = (0..<60).map { i in
            frame(angle: Double(i) / 60 * 2 * .pi, scale: 0.85 + 0.3 * Double(i % 7) / 6, t: Double(i) / 5)
        }
        let girths = try RotationScanAnalyzer().girths(frames: frames, heightCm: heightCm, levelFractions: fractions)
        let expected = ellipsePerimeter(17, 12)
        #expect(abs(try #require(girths[.chest]).cm - expected) / expected < 0.02)
    }

    @Test func armTouchingInAFewFramesIsIgnored() throws {
        let frames = (0..<60).map { i in
            frame(angle: Double(i) / 60 * 2 * .pi, armAtChest: (10...13).contains(i), t: Double(i) / 5)
        }
        let girths = try RotationScanAnalyzer().girths(frames: frames, heightCm: heightCm, levelFractions: fractions)
        let expected = ellipsePerimeter(17, 12)
        #expect(abs(try #require(girths[.chest]).cm - expected) / expected < 0.02)
    }

    @Test func unevenTurningSpeedIsBalancedByAngle() throws {
        // Lingers facing the camera and back (wide views), rushes through the sides.
        var angles: [Double] = []
        var a = 0.0
        while a < 2 * .pi {
            angles.append(a)
            a += abs(sin(a)) > 0.7 ? 0.25 : 0.05
        }
        let balanced = try RotationScanAnalyzer().girths(
            frames: angles.enumerated().map { frame(angle: $1, t: Double($0) / 6, withAxis: true) },
            heightCm: heightCm, levelFractions: fractions)
        let plain = try RotationScanAnalyzer().girths(
            frames: angles.enumerated().map { frame(angle: $1, t: Double($0) / 6) },
            heightCm: heightCm, levelFractions: fractions)
        let expected = ellipsePerimeter(15, 11)
        let balancedError = abs(try #require(balanced[.waist]).cm - expected) / expected
        let plainError = abs(try #require(plain[.waist]).cm - expected) / expected
        #expect(balancedError < 0.02, "balanced \(balancedError)")
        #expect(balancedError < plainError)
    }

    @Test func readingLocatesLevels() throws {
        let reading = try #require(RotationScanAnalyzer().reading(frame(angle: 0, t: 0), heightCm: heightCm, levelFractions: fractions))
        let waist = try #require(reading.levels[.waist])
        #expect(abs(waist.widthCm - 30) < 0.5)
        #expect(abs(reading.centerX - 0.5) < 0.01)
        #expect(waist.y > reading.top && waist.y < reading.floor)
    }

    @Test func armSpanSeesOutstretchedArms() throws {
        // 180 cm person, 1 px = 0.1 cm: torso 34 cm wide, arms out to 170 cm span at 20%.
        let width = 2000, top = 40, heightPx = 1800, height = heightPx + 100
        var bits = [Bool](repeating: false, count: width * height)
        for y in top..<(top + heightPx) {
            let f = Double(y - top) / Double(heightPx)
            let half = (0.18...0.22).contains(f) ? 850 : 170
            for x in (width / 2 - half)..<(width / 2 + half) { bits[y * width + x] = true }
        }
        let mask = BinaryMask(width: width, height: height, bits: bits)
        // A square-pixel mask: no aspect conversion.
        let span = try #require(RotationScanAnalyzer().armSpan(mask, top: top, height: heightPx, center: width / 2,
                                                              frameAspect: Double(width) / Double(height)))
        #expect(abs(span - 1700.0 / 1800.0) < 0.01)
    }

    @Test func maskStretchedToAnotherAspectIsCorrected() throws {
        // A 9:16 image whose mask came back 3:4: widths look a third larger until resampled.
        let true9x16 = frame(angle: 0, t: 0)
        let squeezedWidth = Int(Double(true9x16.mask.height) * 3 / 4)
        let stretched = true9x16.mask.resampled(width: squeezedWidth, height: true9x16.mask.height)
        let imageAspect = Double(true9x16.mask.width) / Double(true9x16.mask.height)
        let fixed = stretched.matchingAspect(imageAspect)
        #expect(fixed.width == true9x16.mask.width)
        let reading = try #require(RotationScanAnalyzer().reading(
            RotationFrame(mask: fixed, centerX: Double(fixed.width) / 2, time: 0), heightCm: heightCm, levelFractions: fractions))
        #expect(abs(try #require(reading.levels[.waist]).widthCm - 30) < 0.6)
    }

    @Test func armThicknessOfOutstretchedArms() throws {
        // 180 cm (1800 px) person, arms 10 cm thick straight out at shoulder height.
        let width = 2000, top = 40, heightPx = 1800, height = heightPx + 100
        var bits = [Bool](repeating: false, count: width * height)
        for y in top..<(top + heightPx) {
            let f = Double(y - top) / Double(heightPx)
            let half = (0.17...0.225).contains(f) ? 850 : 170
            for x in (width / 2 - half)..<(width / 2 + half) { bits[y * width + x] = true }
        }
        let mask = BinaryMask(width: width, height: height, bits: bits)
        let analyzer = RotationScanAnalyzer()
        let t = try #require(analyzer.armThickness(mask, top: top, height: heightPx, center: width / 2))
        #expect(abs(t - 0.055) < 0.003)
        let outline = analyzer.outline(mask, top: top, floor: top + heightPx - 1)
        #expect(outline.count > 60)
        #expect(outline.contains { $0.right - $0.left > 0.8 })
    }

    @Test func standingStillIsNotATurn() {
        let frames = (0..<60).map { i in frame(angle: 0, t: Double(i) / 5) }
        #expect(throws: RotationScanError.incompleteTurn) {
            try RotationScanAnalyzer().girths(frames: frames, heightCm: heightCm, levelFractions: fractions)
        }
    }

    @Test func tooFewFrames() {
        let frames = (0..<8).map { i in frame(angle: Double(i), t: Double(i)) }
        #expect(throws: RotationScanError.incompleteTurn) {
            try RotationScanAnalyzer().girths(frames: frames, heightCm: heightCm, levelFractions: fractions)
        }
    }
}
