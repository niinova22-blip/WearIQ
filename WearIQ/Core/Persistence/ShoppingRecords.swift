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
    /// tight / right / loose, or "pending" while the order is on its way.
    var feelRaw: String
    /// The size WearIQ recommended when this garment was checked.
    var recommendedSize: String?
    /// Sent back.
    var returned: Bool?
    /// Identifies the record in its follow-up notification.
    var token: String?
    /// The saved analysis it came from, to open it again.
    var productKey: String?
    /// Who it was bought for: nil for the app's own user.
    var personID: UUID?

    static let pendingRaw = "pending"

    init(brand: String, productName: String?, category: GarmentCategory?, size: String, feel: Feel?, createdAt: Date = Date(),
         recommendedSize: String? = nil, productKey: String? = nil, personID: UUID? = nil) {
        self.createdAt = createdAt
        self.brand = brand
        self.productName = productName
        categoryRaw = category?.rawValue
        self.size = size
        feelRaw = feel?.rawValue ?? Self.pendingRaw
        self.recommendedSize = recommendedSize
        self.productKey = productKey
        self.personID = personID
        token = UUID().uuidString
    }

    var feel: Feel { Feel(rawValue: feelRaw) ?? .right }
    /// Ordered, not yet told how it fit.
    var isPending: Bool { feelRaw == Self.pendingRaw && returned != true }
    var category: GarmentCategory? { categoryRaw.flatMap(GarmentCategory.init(rawValue:)) }

    /// Records how it fit (and whether it went back).
    func settle(_ feel: Feel, returned: Bool = false) {
        feelRaw = feel.rawValue
        self.returned = returned
    }
}

/// Someone else the user shops for: a partner, a child, a gift. Has its own body profile,
/// checks and brand sizes.
@Model
final class Person {
    enum Relation: String, CaseIterable, Codable {
        case partner, child, parent, friend, other
    }

    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var relationRaw: String

    init(name: String, relation: Relation, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        relationRaw = relation.rawValue
    }

    var relation: Relation { Relation(rawValue: relationRaw) ?? .other }
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
    /// The price when it was first read, for "the price dropped" on the widget.
    var firstPrice: Double?
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
