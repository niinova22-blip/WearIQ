import Foundation
import Observation
import StoreKit

enum PremiumProduct {
    static let monthly = "com.niinova.weariq.premium.monthly"
    static let yearly = "com.niinova.weariq.premium.yearly"
    static let all = [monthly, yearly]
}

/// Minimal view of a transaction, so entitlement rules can be unit tested without StoreKit.
struct EntitlementRecord: Equatable {
    var productID: String
    var expirationDate: Date?
    var revocationDate: Date?
    var isUpgraded: Bool
}

enum PremiumStatus {
    /// Premium while any known subscription is unrevoked, not superseded and unexpired.
    static func isPremium(_ records: [EntitlementRecord], now: Date) -> Bool {
        records.contains { r in
            PremiumProduct.all.contains(r.productID)
                && r.revocationDate == nil
                && !r.isUpgraded
                && (r.expirationDate.map { $0 > now } ?? false)
        }
    }
}

/// StoreKit 2 subscriptions. Prices and names always come from the App Store; nothing
/// about pricing is hard-coded in the app.
@MainActor
@Observable
final class SubscriptionService {
    private(set) var products: [Product] = []
    private(set) var isPremium = false
    private(set) var isLoading = false
    var lastError: String?

    /// Called whenever entitlement changes (the container mirrors it).
    var onPremiumChange: ((Bool) -> Void)?

    private var updatesTask: Task<Void, Never>?

    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case let .verified(transaction) = update { await transaction.finish() }
                await self?.refreshEntitlements()
            }
        }
        Task {
            await loadProducts()
            await refreshEntitlements()
        }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: PremiumProduct.all)
                .sorted { ($0.subscription?.subscriptionPeriod.unit == .year ? 1 : 0) < ($1.subscription?.subscriptionPeriod.unit == .year ? 1 : 0) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    enum PurchaseOutcome: Equatable {
        case purchased, pending, cancelled, failed
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            switch try await product.purchase() {
            case let .success(.verified(transaction)):
                await transaction.finish()
                await refreshEntitlements()
                return .purchased
            case .success(.unverified):
                lastError = String(localized: "The purchase couldn't be verified.")
                return .failed
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed
            }
        } catch {
            lastError = error.localizedDescription
            return .failed
        }
    }

    /// "Restore purchases": re-syncs receipts with the App Store.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            lastError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    /// Tester builds can unlock Premium without a purchase: the release workflow sets
    /// WQUnlockPremium for TestFlight builds and must leave it off for App Store
    /// submissions, or App Review couldn't see the paywall.
    static let testerUnlock = Bundle.main.object(forInfoDictionaryKey: "WQUnlockPremium") as? Bool ?? false

    func refreshEntitlements() async {
        var records: [EntitlementRecord] = []
        for await result in Transaction.currentEntitlements {
            guard case let .verified(t) = result else { continue }
            records.append(EntitlementRecord(productID: t.productID, expirationDate: t.expirationDate,
                                             revocationDate: t.revocationDate, isUpgraded: t.isUpgraded))
        }
        let premium = Self.testerUnlock || PremiumStatus.isPremium(records, now: Date())
        if premium != isPremium {
            isPremium = premium
        }
        onPremiumChange?(premium)
    }
}
