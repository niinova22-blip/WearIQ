import FitEngine
import Foundation
import ProductMeasurementParser
import Testing
@testable import AvatarEngine
import WearIQCore

/// Cases seen on a phone: a sweatshirt with no size chart (the model wears M) said "sleeves
/// and length ideal" in M and in 2XL while the avatar showed the 2XL's cuffs past the
/// wrist; trousers in 40 were loose at the waist and seat on the chart but fitted below
/// it on the avatar.
@Suite struct ReportedFitTests {
    func body(_ values: [BodyDimension: Double]) -> BodyProfile {
        var p = BodyProfile(values: values.mapValues { MeasuredValue(cm: $0, uncertaintyCm: 1.5, source: .scan) })
        p.sex = .male
        return p
    }

    var man: BodyProfile {
        body([.height: 180, .chest: 98, .waist: 84, .hip: 96, .thigh: 56, .shoulderWidth: 41,
              .armLength: 0.3375 * 180, .torsoLength: 0.262 * 180, .inseam: 0.481 * 180])
    }

    @Test func sweatshirtLengthsGrowWithTheSize() throws {
        let labels = ["XS", "S", "M", "L", "XL", "2XL"]
        let chart = try #require(StandardSizeCharts.chart(for: labels, category: .sweater, audience: .men,
                                                         anchor: ModelFit(size: "M", heightCm: 180)))
        let spec = GarmentSpec(category: .sweater, chartKind: .body, sizes: chart.sizes)
        let analysis = FitEngine().analyze(body: man, garment: spec)
        func verdict(_ size: String, _ region: FitRegion) -> FitVerdict? {
            analysis.sizes.first { $0.label == size }?.regions.first { $0.region == region }?.verdict
        }
        #expect(verdict("M", .sleeve) == .ideal)
        #expect(verdict("M", .bodyLength) == .ideal)
        #expect(verdict("XL", .sleeve) == .long)
        #expect(verdict("2XL", .sleeve) == .long)
        #expect(verdict("2XL", .bodyLength) == .long)
        // The avatar says the same in every size.
        for (entry, size) in zip(spec.sizes, analysis.sizes) {
            let fit = AvatarFitMapper.fit(spec: spec, size: entry, body: man, regions: size.regions)
            let long = size.regions.first { $0.region == .sleeve }?.verdict == .long
            #expect((fit.shownSleeve.delta >= fit.shownSleeve.threshold) == long, "\(entry.label)")
        }
    }

    @Test func trousersTwoSizesUpAreLooseAllTheWayDown() throws {
        let labels = ["30", "32", "34", "36", "38", "40"]
        let chart = try #require(StandardSizeCharts.chart(for: labels, category: .pants, audience: .men))
        let spec = GarmentSpec(category: .pants, chartKind: .body, sizes: chart.sizes)
        let analysis = FitEngine().analyze(body: man, garment: spec)
        let me = try #require(Avatar.Measurements(man))
        let model = BodyModel.make(me)
        func looseShare(_ label: String) throws -> (thigh: Double, knee: Double, fit: Avatar.GarmentFit) {
            let entry = try #require(spec.sizes.first { $0.label == label })
            let regions = try #require(analysis.sizes.first { $0.label == label }).regions
            let fit = AvatarFitMapper.fit(spec: spec, size: entry, body: man, regions: regions)
            let mesh = Avatar(me, garment: fit, detail: .preview).layers[0].mesh
            func share(_ band: ClosedRange<Float>) -> Double {
                let ids = mesh.positions.indices.filter { band.contains(mesh.positions[$0].y) }
                return Double(ids.filter { mesh.tones[$0] == .loose }.count) / Double(max(1, ids.count))
            }
            let thigh = (model.kneeY + 0.08 * model.h)...(model.crotchY - 0.03 * model.h)
            let knee = (model.kneeY - 0.04 * model.h)...(model.kneeY + 0.04 * model.h)
            return (share(thigh), share(knee), fit)
        }
        let big = try looseShare("40")
        #expect(big.fit.judged.zones[.thigh] == .loose)
        #expect(big.thigh > 0.6, "thigh loose share \(big.thigh)")
        #expect(big.knee > 0.6, "knee loose share \(big.knee)")
        // Graded: the 40's thighs are roomier than the 32's, which is what the chart suits.
        let fitting = try looseShare("32")
        #expect(big.fit.thighEase > fitting.fit.thighEase + 8)
        #expect(fitting.thigh < 0.2, "thigh loose share \(fitting.thigh)")
    }

    /// A relaxed T-shirt with a regular one's room is closer than its cut, not tight.
    @Test func relaxedTeeWithRegularRoomIsNotTight() {
        let spec = GarmentSpec(category: .tshirt, fitStyle: .relaxed, chartKind: .garment,
                               sizes: [SizeEntry(label: "M", values: [.chest: MeasuredValue(cm: 108, uncertaintyCm: 0.5, source: .manual)])])
        let r = FitEngine().analyze(body: man, garment: spec).sizes[0].regions.first { $0.region == .chest }
        #expect(r?.verdict == .slightlyTight)
        #expect(r?.byCutOnly == true)
    }
}
