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
@Suite(.serialized) struct StoreKitFlowTests {
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

    @Test func purchaseActivatesPremiumAndExpiryEndsIt() async throws {
        let session = try makeSession()
        let service = SubscriptionService()
        var mirrored: [Bool] = []
        service.onPremiumChange = { mirrored.append($0) }
        await service.loadProducts()
        let monthly = try #require(service.products.first { $0.id == PremiumProduct.monthly })

        #expect(await service.purchase(monthly) == .purchased)
        #expect(service.isPremium)
        #expect(mirrored.last == true)

        try session.expireSubscription(productIdentifier: PremiumProduct.monthly)
        await service.refreshEntitlements()
        #expect(!service.isPremium)
    }

    @Test func refundRevokesPremium() async throws {
        let session = try makeSession()
        let service = SubscriptionService()
        await service.loadProducts()
        let yearly = try #require(service.products.first { $0.id == PremiumProduct.yearly })
        #expect(await service.purchase(yearly) == .purchased)

        let transaction = try #require(session.allTransactions().first)
        try session.refundTransaction(identifier: UInt(transaction.identifier))
        await service.refreshEntitlements()
        #expect(!service.isPremium)
    }

    @Test func restoreKeepsExistingEntitlement() async throws {
        _ = try makeSession()
        let service = SubscriptionService()
        await service.loadProducts()
        let monthly = try #require(service.products.first { $0.id == PremiumProduct.monthly })
        _ = await service.purchase(monthly)

        let fresh = SubscriptionService()
        await fresh.refreshEntitlements()
        #expect(fresh.isPremium)
    }
}
