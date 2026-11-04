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
    let ads = AdvertisingService()
    /// Mirrors the StoreKit entitlement; drives quota, ads and premium features.
    private(set) var isPremium = false
    /// A product link handed over by the share extension, for the scan tab to check.
    var pendingProductLink: URL?
    /// A purchase whose fit the user is asked about (from its follow-up notification).
    var pendingPurchaseToken: String?
    /// A checked garment to open (from Siri, Spotlight or visual intelligence).
    var pendingAnalysisKey: String?

    /// Whose measurements the app is using: nil for the user, otherwise a Person
    /// (shopping for a partner, a child, a gift).
    var activePersonID: UUID? = UserDefaults.standard.string(forKey: "activePersonID").flatMap(UUID.init(uuidString:)) {
        didSet { UserDefaults.standard.set(activePersonID?.uuidString, forKey: "activePersonID") }
    }

    /// The active person's latest profile among `profiles` (sorted newest first).
    func activeProfile(_ profiles: [StoredBodyProfile]) -> StoredBodyProfile? {
        profiles.first { $0.personID == activePersonID }
    }

    /// weariq://check?url=https://… → the product link; weariq://feedback?token=… → a
    /// purchase to rate.
    func handle(_ url: URL) {
        guard url.scheme == "weariq" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if url.host == "feedback", let token = items.first(where: { $0.name == "token" })?.value {
            pendingPurchaseToken = token
            return
        }
        guard url.host == "check", let value = items.first(where: { $0.name == "url" })?.value,
              let link = URL(string: value), link.scheme?.hasPrefix("http") == true else { return }
        pendingProductLink = link
    }

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
        FitAnalysisCoordinator(context: modelContainer.mainContext, quota: quota, engine: fitEngine, isPremium: isPremium,
                               personID: activePersonID)
    }

    static func live() -> AppContainer {
        #if DEBUG
        if DemoMode.isActive { return demo() }
        #endif
        return AppContainer(modelContainer: PersistenceController.makeContainer(inMemory: false),
                     quotaStore: KeychainQuotaStore(),
                     fitEngine: FitEngine())
    }

    static func preview() -> AppContainer {
        AppContainer(modelContainer: PersistenceController.makeContainer(inMemory: true),
                     quotaStore: KeychainQuotaStore(service: "preview.\(UUID().uuidString)"),
                     fitEngine: FitEngine())
    }

    #if DEBUG
    /// Sample data for App Store screenshots; Premium so the wardrobe and style tabs show content.
    private static func demo() -> AppContainer {
        let app = preview()
        try? DemoMode.seed(app.modelContainer.mainContext, engine: app.fitEngine)
        app.onboardingCompleted = true
        app.isPremium = true
        app.subscriptions.onPremiumChange = nil
        return app
    }
    #endif

    /// Removes every piece of personal data: body profile, history and wardrobe.
    /// The scan quota is deliberately kept (it holds only hashed product keys), otherwise
    /// "delete my data" would become a way to get a fresh daily allowance.
    func deleteAllPersonalData() throws {
        let context = modelContainer.mainContext
        try context.delete(model: StoredBodyProfile.self)
        try context.delete(model: SavedAnalysis.self)
        try context.delete(model: WardrobeEntry.self)
        try context.delete(model: Person.self)
        try context.delete(model: PurchaseRecord.self)
        try context.delete(model: TrackedProduct.self)
        try context.save()
        activePersonID = nil
        WidgetSnapshot.clear()
        CloudBackup.erase()
        UserDefaults.standard.set(false, forKey: CloudBackup.enabledKey)
        onboardingCompleted = false
    }
}
