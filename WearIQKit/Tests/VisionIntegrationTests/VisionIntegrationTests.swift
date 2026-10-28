#if canImport(Vision)
import BodyMeasurementEngine
import BodyScanVision
import Foundation
import ImageIO
import ProductMeasurementParser
import Testing
import Vision
import WearIQCore

/// Runs the real Apple Vision pipeline on images (macOS CI). These check that the
/// pipeline works end to end on real pixels; they are not accuracy measurements.
@Suite struct VisionIntegrationTests {
    private func image(_ name: String) throws -> CGImage {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Resources"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @Test func frontPhotoProducesPlausibleMeasurements() throws {
        let photo = try image("front_studio_1896.jpg")
        let (mask, joints) = try VisionBodyAnalyzer().analyze(photo)
        print("mask \(mask.width)x\(mask.height), joints: \(joints.keys.map(\.rawValue).sorted())")
        let front = try SilhouetteAnalyzer().analyzeFront(mask: mask, joints: joints)
        print("levels: \(front.levels.mapValues { Int($0.extentPx) }), height px \(Int(front.personHeightPx)), crotch \(front.crotchY.map { Int($0) } ?? -1)")

        // Unknown subject: assume an average 1890s man, 172 cm / 65 kg.
        let scanned = try BodyMeasurementEngine().measure(heightCm: 172, front: front, side: nil)
        let prior = AnthropometricPrior().estimate(heightCm: 172, weightKg: 65, sex: .male)
        let (fused, rejected) = MeasurementFusion.fuse(scan: scanned, prior: prior)
        for d in BodyDimension.allCases {
            let s = scanned[d].map { String(format: "%.1f±%.1f", $0.cm, $0.uncertaintyCm) } ?? "-"
            let p = prior[d].map { String(format: "%.1f", $0.cm) } ?? "-"
            let f = fused[d].map { String(format: "%.1f (%@)", $0.cm, $0.source.rawValue) } ?? "-"
            print("\(d.rawValue): scan \(s) | estimate \(p) | final \(f)")
        }
        print("rejected scan values: \(rejected.map(\.rawValue))")

        #expect(joints.count >= 10)
        #expect(scanned[.shoulderWidth] != nil)
        #expect(scanned[.chest] != nil)
        // Every dimension ends up with a value, all in a plausible adult range.
        for (d, range) in [(BodyDimension.chest, 70.0...140.0), (.waist, 55...130), (.hip, 75...140),
                           (.shoulderWidth, 30...55), (.inseam, 65...95), (.armLength, 45...75)] {
            let v = try #require(fused[d], "\(d)")
            #expect(range.contains(v.cm), "\(d) = \(v.cm)")
        }
    }

    @Test func sizeChartImageWithSizesInRows() throws {
        let chart = try image("size_chart_rows.png")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["tr-TR", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: chart, orientation: .up).perform([request])
        let boxes = (request.results ?? []).compactMap { obs -> TextBox? in
            guard let text = obs.topCandidates(1).first?.string else { return nil }
            let b = obs.boundingBox
            return TextBox(text: text, minX: b.minX, midY: 1 - b.midY, height: b.height, width: b.width)
        }
        print(boxes.map(\.text))

        let sections = SizeTableReader.sections(from: boxes)
        print(sections.map { "\($0.title ?? "-") \($0.fitStyle.map(\.rawValue) ?? "-") \($0.chart.sizes.map(\.label))" })
        #expect(sections.count == 2)
        let slim = try #require(SizeTableReader.best(sections, fit: .slim))
        let m = try #require(slim.chart.sizes.first { $0.label == "M" })
        #expect(m.values[.chest]?.cm == 104)
        #expect(m.values[.shoulderWidth]?.cm == 45)
        #expect(m.values[.sleeveLength]?.cm == 67)
        #expect(SizeTableReader.best(sections, fit: .regular)?.chart.sizes.map(\.label) == ["M", "L", "XL"])
    }
}
#endif
