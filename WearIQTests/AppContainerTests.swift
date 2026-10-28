import Foundation
import ScanQuota
import SwiftData
import Testing
import WearIQCore
@testable import WearIQ

@MainActor
@Suite struct AppContainerTests {
    @Test func deletingDataRemovesProfileAndResetsOnboarding() throws {
        let container = AppContainer.preview()
        let context = container.modelContainer.mainContext
        context.insert(try StoredBodyProfile(profile: BodyProfile(values: [.chest: .manual(100)])))
        try context.save()
        container.onboardingCompleted = true

        try container.deleteAllPersonalData()

        #expect(try context.fetch(FetchDescriptor<StoredBodyProfile>()).isEmpty)
        #expect(container.onboardingCompleted == false)
    }

    @Test func storedProfileRoundTrips() throws {
        let profile = BodyProfile(values: [.waist: MeasuredValue(cm: 84, uncertaintyCm: 3, source: .scan)])
        let stored = try StoredBodyProfile(profile: profile)
        #expect(stored.profile?[.waist]?.cm == 84)
        #expect(stored.profile?[.waist]?.source == .scan)
    }

    @Test func keychainQuotaStorePersists() {
        let store = KeychainQuotaStore(service: "test.\(UUID().uuidString)")
        let state = QuotaState(day: "2026-10-28", consumedProductKeys: ["abc"],
                               highWaterMark: Date(timeIntervalSince1970: 1_793_170_800))
        store.save(state)
        #expect(store.load() == state)
    }
}
