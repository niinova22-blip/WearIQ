import FitEngine
import Foundation
import OutfitRecommendationEngine
import SwiftData
import Testing
import WearIQCore
@testable import WearIQ

@MainActor
@Suite final class WardrobeTests {
    private var container: ModelContainer?

    @Test func entryRoundTripsToEngineItem() throws {
        let container = PersistenceController.makeContainer(inMemory: true)
        self.container = container
        let entry = WardrobeEntry(name: "Oxford", category: .top, color: .white, seasons: [.spring, .autumn],
                                  styles: [.business], fitScore: 0.9)
        container.mainContext.insert(entry)
        try container.mainContext.save()

        let fetched = try #require(try container.mainContext.fetch(FetchDescriptor<WardrobeEntry>()).first)
        let item = fetched.item
        #expect(item.category == .top)
        #expect(item.color == .white)
        #expect(item.seasons == [.spring, .autumn])
        #expect(item.styles == [.business])
        #expect(item.fitScore == 0.9)
    }

    @Test func deleteAllDataRemovesWardrobe() throws {
        let app = AppContainer.preview()
        app.modelContainer.mainContext.insert(WardrobeEntry(name: "Tee", category: .top, color: .black))
        try app.modelContainer.mainContext.save()
        try app.deleteAllPersonalData()
        #expect(try app.modelContainer.mainContext.fetch(FetchDescriptor<WardrobeEntry>()).isEmpty)
    }

    @Test func sizeFitScoreReflectsSeverity() {
        func region(_ s: FitSeverity) -> RegionFit {
            RegionFit(region: .chest, verdict: .ideal, severity: s, estimatedOffsetCm: nil,
                      probabilityIdeal: nil, confidence: .high, missing: nil)
        }
        let fit = SizeFit(label: "M", regions: [region(.good), region(.minor), region(.unknown)], penalty: 0, hasCriticalData: true)
        #expect(fit.fitScore == 0.8)
        #expect(SizeFit(label: "S", regions: [region(.unknown)], penalty: 0, hasCriticalData: false).fitScore == nil)
    }

    @Test func garmentCategoryMapping() {
        #expect(WardrobeCategory(GarmentCategory.jacket) == .outerwear)
        #expect(WardrobeCategory(GarmentCategory.pants) == .bottom)
        #expect(WardrobeCategory(GarmentCategory.tshirt) == .top)
    }

    @Test func currentSeason() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let oct = cal.date(from: DateComponents(year: 2026, month: 10, day: 28))!
        let jan = cal.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        #expect(Season.current(oct, calendar: cal) == .autumn)
        #expect(Season.current(jan, calendar: cal) == .winter)
    }
}
