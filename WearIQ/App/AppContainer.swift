import FitEngine
import Observation
import ScanQuota
import SwiftData
import SwiftUI

/// Composition root. Every feature gets its dependencies from here through protocols,
/// so engines and services can be swapped for fakes in tests and previews.
@MainActor
@Observable
final class AppContainer {
    let modelContainer: ModelContainer
    let quota: DailyScanQuotaManager
    let fitEngine: any FitAnalyzing

    let subscriptions = SubscriptionService()
    /// Mirrors the StoreKit entitlement; drives quota, ads and premium features.
    private(set) var isPremium = false

    var onboardingCompleted = UserDefaults.standard.bool(forKey: AppContainer.onboardingKey) {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: Self.onboardingKey) }
    }
    private static let onboardingKey = "onboardingCompleted"

    init(modelContainer: ModelContainer, quotaStore: KeychainQuotaStore, fitEngine: any FitAnalyzing) {
        self.modelContainer = modelContainer
        self.quota = DailyScanQuotaManager(store: quotaStore)
        self.fitEngine = fitEngine
        subscriptions.onPremiumChange = { [weak self] premium in self?.isPremium = premium }
    }

    func analysisCoordinator() -> FitAnalysisCoordinator {
        FitAnalysisCoordinator(context: modelContainer.mainContext, quota: quota, engine: fitEngine, isPremium: isPremium)
    }

    static func live() -> AppContainer {
        AppContainer(modelContainer: PersistenceController.makeContainer(inMemory: false),
                     quotaStore: KeychainQuotaStore(),
                     fitEngine: FitEngine())
    }

    static func preview() -> AppContainer {
        AppContainer(modelContainer: PersistenceController.makeContainer(inMemory: true),
                     quotaStore: KeychainQuotaStore(service: "preview.\(UUID().uuidString)"),
                     fitEngine: FitEngine())
    }

    /// Removes every piece of personal data: body profile, history and wardrobe.
    /// The scan quota is deliberately kept (it holds only hashed product keys), otherwise
    /// "delete my data" would become a way to get a fresh daily allowance.
    func deleteAllPersonalData() throws {
        let context = modelContainer.mainContext
        try context.delete(model: StoredBodyProfile.self)
        try context.delete(model: SavedAnalysis.self)
        try context.save()
        onboardingCompleted = false
    }
}
