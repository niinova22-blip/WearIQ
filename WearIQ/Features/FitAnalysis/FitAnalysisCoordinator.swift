import FitEngine
import Foundation
import ScanQuota
import SwiftData
import WearIQCore

/// Runs an analysis end-to-end: body profile → quota → fit engine → save.
///
/// Quota rules: only a successful new analysis consumes a scan. An analysis that ends in
/// "insufficient data" is a failed lookup and is free; re-analysing the same product the
/// same day is free; reopening a saved analysis never comes through here.
@MainActor
struct FitAnalysisCoordinator {
    enum Outcome {
        case analyzed(SavedAnalysis)
        case insufficientData(FitAnalysis)
        case needsBodyProfile
        case quotaExhausted
        case invalidDraft([GarmentDraft.Issue])
    }

    let context: ModelContext
    let quota: DailyScanQuotaManager
    let engine: any FitAnalyzing
    let isPremium: Bool

    func run(_ draft: GarmentDraft, preference: FitPreference) throws -> Outcome {
        guard let spec = draft.spec else { return .invalidDraft(draft.issues) }
        guard let body = try latestBodyProfile() else { return .needsBodyProfile }

        let key = draft.productKey
        if quota.check(productKey: key, isPremium: isPremium) == .exhausted { return .quotaExhausted }

        let analysis = engine.analyze(body: body, garment: spec, preference: preference)
        if case .insufficientData = analysis.recommendation { return .insufficientData(analysis) }

        guard quota.recordSuccess(productKey: key, isPremium: isPremium) else { return .quotaExhausted }

        let existing = FetchDescriptor<SavedAnalysis>(predicate: #Predicate { $0.productKey == key })
        try context.fetch(existing).forEach(context.delete)
        let saved = try SavedAnalysis(productKey: key, productName: draft.info.name, brand: draft.info.brand,
                                      imageURL: draft.info.imageURL, pageURL: draft.info.pageURL,
                                      spec: spec, analysis: analysis, material: draft.info.material)
        context.insert(saved)
        try context.save()
        return .analyzed(saved)
    }

    private func latestBodyProfile() throws -> BodyProfile? {
        var descriptor = FetchDescriptor<StoredBodyProfile>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.profile
    }
}
