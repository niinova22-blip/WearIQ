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

    private func frame(angle: Double, scale: Double = 1, armAtChest: Bool = false, t: Double) -> RotationFrame {
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
        return RotationFrame(mask: BinaryMask(width: width, height: height, bits: bits), centerX: Double(width / 2), time: t)
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
