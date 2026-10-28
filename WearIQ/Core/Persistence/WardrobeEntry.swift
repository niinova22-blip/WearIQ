import FitEngine
import Foundation
import OutfitRecommendationEngine
import SwiftData
import WearIQCore

/// A garment the user owns.
@Model
final class WardrobeEntry {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var name: String
    var brand: String?
    var size: String?
    var categoryRaw: String
    var colorRaw: String
    var fitStyleRaw: String?
    var seasonsRaw: [String]
    var stylesRaw: [String]
    var fitScore: Double?
    @Attribute(.externalStorage) var photo: Data?

    init(name: String, category: WardrobeCategory, color: ColorFamily, brand: String? = nil, size: String? = nil,
         fitStyle: FitStyle? = nil, seasons: Set<Season> = Set(Season.allCases), styles: Set<StyleTag> = [.casual],
         fitScore: Double? = nil, photo: Data? = nil) {
        id = UUID()
        createdAt = Date()
        self.name = name
        self.brand = brand
        self.size = size
        categoryRaw = category.rawValue
        colorRaw = color.rawValue
        fitStyleRaw = fitStyle?.rawValue
        seasonsRaw = seasons.map(\.rawValue).sorted()
        stylesRaw = styles.map(\.rawValue).sorted()
        self.fitScore = fitScore
        self.photo = photo
    }

    var category: WardrobeCategory {
        get { WardrobeCategory(rawValue: categoryRaw) ?? .top }
        set { categoryRaw = newValue.rawValue }
    }

    var color: ColorFamily {
        get { ColorFamily(rawValue: colorRaw) ?? .multicolor }
        set { colorRaw = newValue.rawValue }
    }

    var fitStyle: FitStyle? {
        get { fitStyleRaw.flatMap(FitStyle.init(rawValue:)) }
        set { fitStyleRaw = newValue?.rawValue }
    }

    var seasons: Set<Season> {
        get { Set(seasonsRaw.compactMap(Season.init(rawValue:))) }
        set { seasonsRaw = newValue.map(\.rawValue).sorted() }
    }

    var styles: Set<StyleTag> {
        get { Set(stylesRaw.compactMap(StyleTag.init(rawValue:))) }
        set { stylesRaw = newValue.map(\.rawValue).sorted() }
    }

    var item: WardrobeItem {
        WardrobeItem(id: id, name: name, category: category, color: color, seasons: seasons, styles: styles, fitScore: fitScore)
    }
}

extension WardrobeCategory {
    init(_ garment: GarmentCategory) {
        switch garment {
        case .shirt, .tshirt: self = .top
        case .jacket: self = .outerwear
        case .pants: self = .bottom
        }
    }
}

extension SizeFit {
    /// 0–1 summary of how well a size fits, for ranking wardrobe items in outfits.
    var fitScore: Double? {
        let scored = regions.compactMap { r -> Double? in
            switch r.severity {
            case .good: 1
            case .minor: 0.6
            case .major: 0.2
            case .unknown: nil
            }
        }
        return scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count)
    }
}
