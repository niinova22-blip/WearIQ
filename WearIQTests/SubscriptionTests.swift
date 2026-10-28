import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import WearIQ

@Suite struct PremiumStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String = PremiumProduct.monthly, expires: TimeInterval? = 3600,
                        revoked: Bool = false, upgraded: Bool = false) -> EntitlementRecord {
        EntitlementRecord(productID: id, expirationDate: expires.map { now.addingTimeInterval($0) },
                          revocationDate: revoked ? now : nil, isUpgraded: upgraded)
    }

    @Test func activeSubscriptionIsPremium() {
        #expect(PremiumStatus.isPremium([record()], now: now))
    }

    @Test func expiredRevokedOrUpgradedIsNot() {
        #expect(!PremiumStatus.isPremium([record(expires: -1)], now: now))
        #expect(!PremiumStatus.isPremium([record(revoked: true)], now: now))
        #expect(!PremiumStatus.isPremium([record(upgraded: true)], now: now))
        #expect(!PremiumStatus.isPremium([record(expires: nil)], now: now))
        #expect(!PremiumStatus.isPremium([], now: now))
    }

    @Test func upgradeToYearlyKeepsPremium() {
        #expect(PremiumStatus.isPremium([record(upgraded: true), record(PremiumProduct.yearly)], now: now))
    }

    @Test func unknownProductsIgnored() {
        #expect(!PremiumStatus.isPremium([record("com.other.app.sub")], now: now))
    }
}

/// Runs real StoreKit 2 purchase flows against the local WearIQ.storekit configuration.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct StoreKitFlowTests {
    nonisolated static var purchaseTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["WEARIQ_STOREKIT_PURCHASE_TESTS"] == "1"
    }

    private func makeSession() throws -> SKTestSession {
        let session = try SKTestSession(configurationFileNamed: "WearIQ")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        return session
    }

    @Test func loadsProductsWithStorePrices() async throws {
        _ = try makeSession()
        let service = SubscriptionService()
        await service.loadProducts()
        #expect(Set(service.products.map(\.id)) == Set(PremiumProduct.all))
        #expect(service.products.allSatisfy { !$0.displayPrice.isEmpty })
    }

    // Purchases are simulated with SKTestSession.buyProduct: product.purchase() needs a
    // UI scene to confirm in and can't complete inside a hosted unit test.
    //
    // These purchase tests hang on headless GitHub Actions simulators, so they only run
    // when WEARIQ_STOREKIT_PURCHASE_TESTS=1 is set (e.g. in the Xcode scheme on a Mac).
    // Entitlement rules themselves are covered by PremiumStatusTests on CI.

    @Test(.enabled(if: Self.purchaseTestsEnabled))
    func purchaseActivatesPremiumAndExpiryEndsIt() async throws {
        let session = try makeSession()
        let service = SubscriptionService()
        var mirrored: [Bool] = []
        service.onPremiumChange = { mirrored.append($0) }

        _ = try await session.buyProduct(identifier: PremiumProduct.monthly)
        await service.refreshEntitlements()
        #expect(service.isPremium)
        #expect(mirrored.last == true)

        try session.expireSubscription(productIdentifier: PremiumProduct.monthly)
        await service.refreshEntitlements()
        #expect(!service.isPremium)
        #expect(mirrored.last == false)
    }

    @Test(.enabled(if: Self.purchaseTestsEnabled))
    func refundRevokesPremium() async throws {
        let session = try makeSession()
        let service = SubscriptionService()
        let transaction = try await session.buyProduct(identifier: PremiumProduct.yearly)
        await service.refreshEntitlements()
        #expect(service.isPremium)

        try session.refundTransaction(identifier: UInt(transaction.id))
        await service.refreshEntitlements()
        #expect(!service.isPremium)
    }

    @Test(.enabled(if: Self.purchaseTestsEnabled))
    func entitlementSurvivesNewServiceInstance() async throws {
        let session = try makeSession()
        _ = try await session.buyProduct(identifier: PremiumProduct.monthly)

        // Simulates an app relaunch / restore: a fresh service reads current entitlements.
        let fresh = SubscriptionService()
        await fresh.refreshEntitlements()
        #expect(fresh.isPremium)
    }
}
