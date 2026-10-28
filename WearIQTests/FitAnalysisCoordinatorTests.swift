import FitEngine
import Foundation
import ProductMeasurementParser
import ScanQuota
import SwiftData
import Testing
import WearIQCore
@testable import WearIQ

@MainActor
@Suite struct FitAnalysisCoordinatorTests {
    private func m(_ cm: Double) -> MeasuredValue { .manual(cm) }

    private func makeDraft(chest: Double? = 112, url: String = "https://shop.example.com/p/1") -> GarmentDraft {
        var info = ProductInfo()
        info.pageURL = URL(string: url)
        let draft = GarmentDraft(info: info)
        draft.category = .shirt
        draft.chartKind = .garment
        var values: [GarmentDimension: MeasuredValue] = [.shoulderWidth: m(46.5)]
        if let chest { values[.chest] = m(chest) }
        draft.sizes = [SizeEntry(label: "M", values: values)]
        return draft
    }

    private var fullProfile: BodyProfile {
        BodyProfile(values: [.height: m(178), .chest: m(100), .shoulderWidth: m(46), .waist: m(86)])
    }

    private func makeCoordinator(profile: BodyProfile?) throws -> (FitAnalysisCoordinator, ModelContext, DailyScanQuotaManager) {
        let container = PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        if let profile {
            context.insert(try StoredBodyProfile(profile: profile))
            try context.save()
        }
        let quota = DailyScanQuotaManager(store: InMemoryQuotaStore())
        return (FitAnalysisCoordinator(context: context, quota: quota, engine: FitEngine(), isPremium: false), context, quota)
    }

    private func makeCoordinator() throws -> (FitAnalysisCoordinator, ModelContext, DailyScanQuotaManager) {
        try makeCoordinator(profile: fullProfile)
    }

    @Test func successfulAnalysisIsSavedAndConsumesOneScan() throws {
        let (coordinator, context, quota) = try makeCoordinator()
        guard case let .analyzed(saved) = try coordinator.run(makeDraft(), preference: .asDesigned) else {
            Issue.record("expected analyzed"); return
        }
        #expect(saved.analysis?.recommendedSize?.label == "M")
        #expect(quota.remaining() == 3)
        #expect(try context.fetch(FetchDescriptor<SavedAnalysis>()).count == 1)
    }

    @Test func sameProductTwiceIsFreeAndNotDuplicated() throws {
        let (coordinator, context, quota) = try makeCoordinator()
        _ = try coordinator.run(makeDraft(), preference: .asDesigned)
        _ = try coordinator.run(makeDraft(), preference: .asDesigned)
        #expect(quota.remaining() == 3)
        #expect(try context.fetch(FetchDescriptor<SavedAnalysis>()).count == 1)
    }

    @Test func insufficientDataIsFreeAndNotSaved() throws {
        // Pants need the waist; this profile has none.
        let (coordinator, context, quota) = try makeCoordinator(profile: BodyProfile(values: [.height: m(178), .chest: m(100)]))
        let draft = makeDraft()
        draft.category = .pants
        draft.sizes = [SizeEntry(label: "32", values: [.waist: m(88)])]
        guard case .insufficientData = try coordinator.run(draft, preference: .asDesigned) else {
            Issue.record("expected insufficientData"); return
        }
        #expect(quota.remaining() == 4)
        #expect(try context.fetch(FetchDescriptor<SavedAnalysis>()).isEmpty)
    }

    @Test func noBodyProfile() throws {
        let (coordinator, _, quota) = try makeCoordinator(profile: nil)
        guard case .needsBodyProfile = try coordinator.run(makeDraft(), preference: .asDesigned) else {
            Issue.record("expected needsBodyProfile"); return
        }
        #expect(quota.remaining() == 4)
    }

    @Test func quotaExhaustedAfterFourProducts() throws {
        let (coordinator, _, _) = try makeCoordinator()
        for i in 0..<4 {
            _ = try coordinator.run(makeDraft(url: "https://shop.example.com/p/\(i)"), preference: .asDesigned)
        }
        guard case .quotaExhausted = try coordinator.run(makeDraft(url: "https://shop.example.com/p/9"), preference: .asDesigned) else {
            Issue.record("expected quotaExhausted"); return
        }
    }

    @Test func invalidDraftReportsIssues() throws {
        let (coordinator, _, _) = try makeCoordinator()
        let draft = GarmentDraft()
        guard case let .invalidDraft(issues) = try coordinator.run(draft, preference: .asDesigned) else {
            Issue.record("expected invalidDraft"); return
        }
        #expect(issues == [.missingCategory, .missingChartKind, .noSizes])
    }
}

@Suite struct GarmentDraftTests {
    @Test func requiresCriticalMeasurement() {
        let draft = GarmentDraft()
        draft.category = .shirt
        draft.chartKind = .garment
        draft.addSize(label: "M")
        #expect(draft.issues == [.missingCriticalMeasurement(.chest)])
        draft.setValue(110, size: 0, dimension: .chest)
        #expect(draft.issues.isEmpty)
        #expect(draft.spec != nil)
    }

    @Test func appliesParsedChartAndKind() {
        let draft = GarmentDraft()
        draft.apply(SizeChartParser().parse("Body measurements cm\nSize S M\nChest 92 100"))
        #expect(draft.chartKind == .body)
        #expect(draft.sizes.count == 2)
    }

    @Test func chartKeyIsStableForSameChart() {
        let a = GarmentDraft(), b = GarmentDraft()
        for d in [a, b] {
            d.category = .shirt
            d.addSize(label: "M")
            d.setValue(110, size: 0, dimension: .chest)
        }
        #expect(a.productKey == b.productKey)
        #expect(a.productKey.hasPrefix("chart:"))
        b.setValue(112, size: 0, dimension: .chest)
        #expect(a.productKey != b.productKey)
    }

    @Test func inferredAttributesFromProductInfo() {
        var info = ProductInfo()
        info.category = .pants
        info.fitStyle = .slim
        info.stretch = .high
        let draft = GarmentDraft(info: info)
        #expect(draft.category == .pants)
        #expect(draft.fitStyle == .slim)
        #expect(draft.stretch == .high)
    }

    @Test func duplicateSizesIgnored() {
        let draft = GarmentDraft()
        draft.addSize(label: "M")
        draft.addSize(label: " M ")
        draft.addSize(label: "")
        #expect(draft.sizes.count == 1)
    }
}
