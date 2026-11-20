import Testing
@testable import FitEngine
import WearIQCore

@Suite struct DecisionSummaryTests {
    private func region(_ r: FitRegion, _ v: FitVerdict, _ s: FitSeverity) -> RegionFit {
        RegionFit(region: r, verdict: v, severity: s, estimatedOffsetCm: nil, probabilityIdeal: nil,
                  confidence: .medium, missing: nil)
    }

    private var trousers: SizeFit {
        SizeFit(label: "32", regions: [
            region(.hip, .slightlyLoose, .minor),
            region(.thigh, .ideal, .good),
            region(.waist, .ideal, .good),
            region(.inseam, .ideal, .good),
        ], penalty: 0.1, hasCriticalData: true)
    }

    /// "Waist fits · hips roomy · inseam 4 cm longer than your favourite."
    @Test func waistFirstThenWhatIsOffThenTheFavourite() {
        let parts = DecisionSummary.parts(size: trousers, category: .pants,
                                          sizeValues: [.waist: 82, .inseam: 82, .hip: 104],
                                          favourite: [.waist: 82, .inseam: 78, .hip: 104])
        #expect(parts == [.region(.waist, .ideal), .region(.hip, .slightlyLoose), .versusFavourite(.inseam, 4)])
    }

    @Test func withoutAFavouriteTheRegionsAlone() {
        let parts = DecisionSummary.parts(size: trousers, category: .pants)
        #expect(parts == [.region(.waist, .ideal), .region(.hip, .slightlyLoose)])
    }

    /// When everything fits, the deciding region and one more, not a list of "fits".
    @Test func allGoodIsShort() {
        let top = SizeFit(label: "M", regions: [
            region(.chest, .ideal, .good), region(.shoulder, .ideal, .good), region(.sleeve, .ideal, .good),
        ], penalty: 0, hasCriticalData: true)
        let parts = DecisionSummary.parts(size: top, category: .shirt)
        #expect(parts.count == 2)
        #expect(parts.first == .region(.chest, .ideal))
    }

    @Test func unknownRegionsAndTinyDifferencesAreLeftOut() {
        let size = SizeFit(label: "32", regions: [
            region(.waist, .ideal, .good),
            RegionFit(region: .hip, verdict: .insufficientData, severity: .unknown, estimatedOffsetCm: nil,
                      probabilityIdeal: nil, confidence: .low, missing: .garmentMeasurement),
        ], penalty: 0, hasCriticalData: true)
        let parts = DecisionSummary.parts(size: size, category: .pants, sizeValues: [.inseam: 78.4], favourite: [.inseam: 78])
        #expect(parts == [.region(.waist, .ideal)])
    }

    @Test func theRiseComparedWithTheFavourite() {
        let parts = DecisionSummary.parts(size: trousers, category: .pants,
                                          sizeValues: [.frontRise: 24, .inseam: 78],
                                          favourite: [.frontRise: 27, .inseam: 78])
        #expect(parts.contains(.versusFavourite(.frontRise, -3)))
    }
}
