import FitEngine
import Foundation
import SwiftData
import Testing
@testable import WearIQ
import WearIQCore

@MainActor
@Suite struct TesterPanelTests {
    @Test func testShoppersComeWithThirtyChecksEach() throws {
        let app = AppContainer.preview()
        let context = app.modelContainer.mainContext
        try TestShoppers.install(context)
        let people = try context.fetch(FetchDescriptor<Person>())
        let analyses = try context.fetch(FetchDescriptor<SavedAnalysis>())
        let profiles = try context.fetch(FetchDescriptor<StoredBodyProfile>())
        for persona in TestShoppers.all {
            #expect(people.contains { $0.id == persona.id })
            #expect(analyses.filter { $0.personID == persona.id }.count == 30)
            let body = try #require(profiles.of(persona.id).first?.profile)
            #expect(body.sex == persona.sex)
            #expect(body[.chest] != nil && body[.waist] != nil && body[.hip] != nil)
        }
        // Again: replaced, not doubled.
        try TestShoppers.install(context)
        #expect(try context.fetch(FetchDescriptor<SavedAnalysis>()).filter { TestShoppers.isTestPerson($0.personID) }.count == 60)
        TestShoppers.remove(context)
        #expect(try context.fetch(FetchDescriptor<SavedAnalysis>()).filter { TestShoppers.isTestPerson($0.personID) }.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Person>()).filter { TestShoppers.isTestPerson($0.id) }.isEmpty)
    }

    /// A T-shirt an older build saved as shorts is checked again as a top at launch.
    @Test func teeSavedAsShortsIsRepaired() throws {
        let app = AppContainer.preview()
        let context = app.modelContainer.mainContext
        let body = BodyProfile(values: [.height: .manual(174), .chest: .manual(95), .waist: .manual(82), .hip: .manual(94),
                                        .shoulderWidth: .manual(44), .torsoLength: .manual(44)], weightKg: 70, sex: .male)
        context.insert(try StoredBodyProfile(profile: body))
        let shorts = GarmentSpec(category: .shorts, fitStyle: .oversized, chartKind: .body,
                                 sizes: ["S", "M", "L"].map { SizeEntry(label: $0, values: [.waist: .manual(80)]) }, legCut: .wide)
        let saved = try SavedAnalysis(productKey: "tee", productName: "Beyaz Boxy Fit Kalın Kumaş Tişört /05", brand: "LCW Vision",
                                      imageURL: nil, pageURL: nil, spec: shorts,
                                      analysis: FitEngine().analyze(body: body, garment: shorts, preference: .asDesigned))
        context.insert(saved)
        #expect(SavedAnalysisRepair.run(context) == 1)
        #expect(saved.spec?.category == .tshirt)
        #expect(saved.analysis?.sizes.first?.regions.contains { $0.region == .chest } == true)
        // Nothing left to repair the second time.
        #expect(SavedAnalysisRepair.run(context) == 0)
    }
}
