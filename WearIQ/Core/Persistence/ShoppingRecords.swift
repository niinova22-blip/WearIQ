import Foundation
import SwiftData
import WearIQCore

/// A garment the user bought, the size taken and how it fit. Builds the per-brand memory
/// that adjusts later advice for the same brand.
@Model
final class PurchaseRecord {
    enum Feel: String, CaseIterable, Codable {
        case tight, right, loose
    }

    var createdAt: Date
    var brand: String
    var productName: String?
    var categoryRaw: String?
    var size: String
    var feelRaw: String

    init(brand: String, productName: String?, category: GarmentCategory?, size: String, feel: Feel, createdAt: Date = Date()) {
        self.createdAt = createdAt
        self.brand = brand
        self.productName = productName
        categoryRaw = category?.rawValue
        self.size = size
        feelRaw = feel.rawValue
    }

    var feel: Feel { Feel(rawValue: feelRaw) ?? .right }
    var category: GarmentCategory? { categoryRaw.flatMap(GarmentCategory.init(rawValue:)) }
}

/// A product followed for a price drop or for the wanted size coming back in stock.
@Model
final class TrackedProduct {
    @Attribute(.unique) var pageURLString: String
    var createdAt: Date
    var productName: String?
    var imageURLString: String?
    var size: String?
    var lastPrice: Double?
    var currency: String?
    var sizeInStock: Bool?
    var lastCheckedAt: Date?

    init(pageURL: URL, productName: String?, imageURL: URL?, size: String?) {
        pageURLString = pageURL.absoluteString
        createdAt = Date()
        self.productName = productName
        imageURLString = imageURL?.absoluteString
        self.size = size
    }

    var pageURL: URL? { URL(string: pageURLString) }
    var imageURL: URL? { imageURLString.flatMap(URL.init(string:)) }
}
