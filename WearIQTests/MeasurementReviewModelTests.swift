import Foundation
import Testing
import WearIQCore
@testable import WearIQ

@Suite struct MeasurementReviewModelTests {
    private let scanned = BodyProfile(values: [
        .height: MeasuredValue(cm: 180, uncertaintyCm: 1, source: .userProvided),
        .chest: MeasuredValue(cm: 98, uncertaintyCm: 9, source: .scan),
        .waist: MeasuredValue(cm: 84, uncertaintyCm: 3, source: .scan),
    ])

    @Test func manualValueReplacesScanWithHighConfidence() throws {
        let model = MeasurementReviewModel(profile: scanned)
        #expect(model.lowConfidence == [.chest])
        try model.setManual(.chest, cm: 101)
        #expect(model.value(.chest)?.source == .manual)
        #expect(model.value(.chest)?.cm == 101)
        #expect(model.lowConfidence.isEmpty)
    }

    @Test func rejectsImplausibleValues() {
        let model = MeasurementReviewModel(profile: scanned)
        #expect(throws: MeasurementReviewModel.EditError.self) { try model.setManual(.waist, cm: 8.4) }
        #expect(model.value(.waist)?.cm == 84)
    }

    @Test func heightCannotBeCleared() {
        let model = MeasurementReviewModel(profile: scanned)
        model.clear(.height)
        model.clear(.waist)
        #expect(model.value(.height) != nil)
        #expect(model.value(.waist) == nil)
        #expect(model.missingEssentials == [.waist])
    }

    @Test func manualOnlyProfileNeedsEssentials() {
        let model = MeasurementReviewModel(profile: BodyProfile(values: [.height: .manual(170)]))
        #expect(model.canSave)
        #expect(model.missingEssentials == [.chest, .waist])
    }

    @Test func formattingShowsUncertaintyOnlyForScans() {
        #expect(MeasuredValue(cm: 98, uncertaintyCm: 4, source: .scan).formatted.contains("±"))
        #expect(!MeasuredValue.manual(98).formatted.contains("±"))
    }
}
