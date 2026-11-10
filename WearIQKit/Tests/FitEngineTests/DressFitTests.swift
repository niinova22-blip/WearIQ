import Testing
@testable import FitEngine
import WearIQCore

/// Dresses as stores chart them (LivePageAudit, 2026-11-10).
@Suite struct DressFitTests {
    private func m(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .scan) }
    private func g(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 0.5, source: .manual) }

    /// Koton's short-sleeved maxi dress, 10% elastane, flat measurements doubled. A size S
    /// woman was sent to XXL: the 13.5 cm sleeve was judged against her 56 cm arm, and a
    /// dress's bodice was given a shirt's ease.
    @Test func shortSleevedDressFitsItsSize() {
        let woman = BodyProfile(values: [.height: m(165), .chest: m(86), .waist: m(68), .hip: m(94),
                                         .armLength: m(56), .torsoLength: m(41), .shoulderWidth: m(37)], sex: .female)
        let rows: [(String, Double, Double, Double)] = [("XS", 82, 64, 13.5), ("S", 86, 68, 14), ("M", 90, 72, 14.5),
                                                        ("L", 96, 78, 15), ("XL", 102, 84, 15.5), ("XXL", 108, 90, 16)]
        let spec = GarmentSpec(category: .dress, fitStyle: .regular, stretch: .high, chartKind: .garment,
                               sizes: rows.map { SizeEntry(label: $0.0, values: [.chest: g($0.1), .waist: g($0.2),
                                                                                 .sleeveLength: g($0.3), .bodyLength: g(129)]) })
        let analysis = FitEngine().analyze(body: woman, garment: spec)
        let picked: [String] = switch analysis.recommendation {
        case let .size(label, _): [label]
        case let .between(a, b): [a, b]
        case .insufficientData: []
        }
        #expect(!picked.isEmpty && picked.allSatisfy { ["S", "M"].contains($0) }, "got \(picked)")
        // The sleeve isn't judged, and a maxi length isn't "too long".
        let s = analysis.sizes.first { $0.label == "S" }
        #expect(s?.region(.sleeve) == nil)
        #expect(s?.region(.bodyLength)?.verdict != .long)
    }
}
