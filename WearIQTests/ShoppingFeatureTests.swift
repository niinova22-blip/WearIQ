import Foundation
import ProductMeasurementParser
import Testing
@testable import WearIQ
import WearIQCore

@MainActor
@Suite struct ShoppingFeatureTests {
    @Test func brandThatRunsSmall() {
        let records = [
            PurchaseRecord(brand: "Koton", productName: nil, category: .tshirt, size: "M", feel: .tight),
            PurchaseRecord(brand: "KOTON ", productName: nil, category: .tshirt, size: "L", feel: .tight),
            PurchaseRecord(brand: "Mavi", productName: nil, category: .tshirt, size: "M", feel: .loose),
        ]
        let memory = BrandMemory(records: records)
        #expect(memory.lean(brand: "koton", category: .tshirt) == .runsSmall)
        #expect(memory.lean(brand: "Mavi", category: .tshirt) == .runsLarge)
        #expect(memory.lean(brand: "Zara", category: .tshirt) == nil)
        #expect(memory.note(brand: "Koton", category: .tshirt, recommended: "M") != nil)
    }

    @Test func priceDropAndSizeBackInStock() throws {
        let product = TrackedProduct(pageURL: URL(string: "https://example.com/p-1")!, productName: "Tişört", imageURL: nil, size: "M")
        product.lastPrice = 399
        product.sizeInStock = false
        var info = ProductInfo()
        info.price = 299
        info.currency = "TRY"
        info.sizeStock = ["M": true]
        let changes = ProductTracker.changes(for: product, now: info)
        #expect(changes.contains { if case .priceDropped(399, 299, _) = $0.kind { true } else { false } })
        #expect(changes.contains { $0.kind == .backInStock(size: "M") })

        // Nothing new: no notification.
        product.lastPrice = 299
        product.sizeInStock = true
        #expect(ProductTracker.changes(for: product, now: info).isEmpty)
    }

    @Test func sharedLinkOpensTheScanTab() {
        let app = AppContainer.preview()
        app.handle(URL(string: "weariq://check?url=https%3A%2F%2Fwww.trendyol.com%2Fx-p-123456")!)
        #expect(app.pendingProductLink?.absoluteString == "https://www.trendyol.com/x-p-123456")
        app.pendingProductLink = nil
        app.handle(URL(string: "weariq://check?url=javascript:alert(1)")!)
        #expect(app.pendingProductLink == nil)
    }

    @Test func tapeCalibrationLearnsAndIsLimited() {
        UserDefaults.standard.removeObject(forKey: "tapeCalibration")
        defer { UserDefaults.standard.removeObject(forKey: "tapeCalibration") }
        #expect(TapeCalibration.factor(.waist) == 1)
        TapeCalibration.record(.waist, scanned: 90, tape: 84)
        let f = TapeCalibration.factor(.waist)
        // One tape value moves the scan half-way: 84/90 → about 0.967.
        #expect(abs(f - (1 + (84.0 / 90 - 1) / 2)) < 0.001)
        // A completely different number isn't a correction.
        TapeCalibration.record(.chest, scanned: 95, tape: 40)
        #expect(TapeCalibration.factor(.chest) == 1)
    }

    @Test func returnRiskReasons() {
        let between = FitAnalysis(recommendation: .between(smaller: "M", larger: "L"), sizes: [])
        #expect(!BulkRisk.reasons(between, standardChart: false).isEmpty)
        let sure = FitAnalysis(recommendation: .size(label: "M", confidence: .high), sizes: [])
        #expect(BulkRisk.reasons(sure, standardChart: false).isEmpty)
        #expect(BulkRisk.reasons(sure, standardChart: true).count == 1)
    }
}
