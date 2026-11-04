import FitEngine
import Foundation
import SwiftData
import Testing
@testable import WearIQ
import WearIQCore

@MainActor
@Suite struct PeopleAndPurchaseTests {
    @Test func feedbackLinkSetsThePurchaseToAsk() {
        let container = AppContainer.preview()
        container.handle(URL(string: "weariq://feedback?token=abc")!)
        #expect(container.pendingPurchaseToken == "abc")
        #expect(container.pendingProductLink == nil)
        container.handle(URL(string: "weariq://check?url=https://example.com/p")!)
        #expect(container.pendingProductLink?.absoluteString == "https://example.com/p")
    }

    @Test func activePersonPicksTheirProfile() throws {
        let container = AppContainer.preview()
        let partner = UUID()
        let mine = try StoredBodyProfile(profile: BodyProfile(values: [.chest: .manual(100)], createdAt: Date(timeIntervalSince1970: 10)))
        let theirs = try StoredBodyProfile(profile: BodyProfile(values: [.chest: .manual(88)], createdAt: Date(timeIntervalSince1970: 20)),
                                           personID: partner)
        let profiles = [theirs, mine]
        container.activePersonID = nil
        #expect(container.activeProfile(profiles)?.profile?[.chest]?.cm == 100)
        container.activePersonID = partner
        #expect(container.activeProfile(profiles)?.profile?[.chest]?.cm == 88)
        #expect(profiles.of(partner).count == 1)
        container.activePersonID = nil
    }

    @Test func pendingOrdersDoNotTeachTheBrandMemory() {
        let pending = PurchaseRecord(brand: "Koton", productName: nil, category: .tshirt, size: "M", feel: nil)
        #expect(pending.isPending)
        #expect(BrandMemory(records: [pending]).lean(brand: "Koton", category: .tshirt) == nil)
        pending.settle(.tight)
        #expect(!pending.isPending)
        #expect(BrandMemory(records: [pending]).lean(brand: "Koton", category: .tshirt) == .runsSmall)
    }

    @Test func fitRecordUsesTheEarlierSizeAsUsual() {
        let first = PurchaseRecord(brand: "Mavi", productName: nil, category: .pants, size: "32", feel: .tight,
                                   createdAt: Date(timeIntervalSince1970: 1), recommendedSize: "33")
        let second = PurchaseRecord(brand: "Mavi", productName: nil, category: .pants, size: "33", feel: .right,
                                    createdAt: Date(timeIntervalSince1970: 2), recommendedSize: "33")
        let summary = PurchaseFollowUp.summary([second, first])
        #expect(summary.followedAdvice == 1)
        #expect(summary.adviceFitFirstTime == 1)
        #expect(summary.likelyReturnsAvoided == 1)
    }
}
