import FitEngine
import Foundation
import SwiftData
import WearIQCore

/// A completed fit analysis. Reopening it never touches the scan quota.
@Model
final class SavedAnalysis {
    @Attribute(.unique) var productKey: String
    var createdAt: Date
    var productName: String?
    var brand: String?
    var imageURLString: String?
    var pageURLString: String?
    var specData: Data
    var analysisData: Data
    /// Fabric composition from the product page, e.g. "%98 Pamuk %2 Elastan".
    var material: String?

    init(productKey: String, productName: String?, brand: String?, imageURL: URL?, pageURL: URL?,
         spec: GarmentSpec, analysis: FitAnalysis, material: String? = nil, createdAt: Date = Date()) throws {
        self.material = material
        self.productKey = productKey
        self.createdAt = createdAt
        self.productName = productName
        self.brand = brand
        imageURLString = imageURL?.absoluteString
        pageURLString = pageURL?.absoluteString
        specData = try JSONEncoder().encode(spec)
        analysisData = try JSONEncoder().encode(analysis)
    }

    var spec: GarmentSpec? { try? JSONDecoder().decode(GarmentSpec.self, from: specData) }
    var analysis: FitAnalysis? { try? JSONDecoder().decode(FitAnalysis.self, from: analysisData) }
    var imageURL: URL? { imageURLString.flatMap(URL.init(string:)) }
    var pageURL: URL? { pageURLString.flatMap(URL.init(string:)) }
}
