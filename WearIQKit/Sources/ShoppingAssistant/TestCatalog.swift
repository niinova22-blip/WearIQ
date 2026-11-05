import Foundation
import ProductMeasurementParser
import WearIQCore

/// Thirty products each for a test woman and a test man, for the testers' panel in
/// TestFlight builds: every kind of garment, cut and leg the engines handle, sized the
/// way the app sizes real pages. Two thirds are what a store page without a chart gives
/// (typical measurements for its size labels, with lengths from the model's height, as
/// `ProductSpec.make` builds them); the rest have the store's own garment measurements,
/// made from the same sizes with the ease of their cut, so the chart-reading paths
/// (sleeves, lengths, cut ease) are exercised too. Names are made up and the brand is
/// "WearIQ Test": no real product is described.
public enum TestCatalog {
    public struct Product: Sendable {
        public var key: String
        public var name: String
        public var brand: String
        public var material: String
        public var spec: GarmentSpec
    }

    public static let brand = "WearIQ Test"

    /// What a product is: its name, kind, cut, legs, fabric, and whether the store gives
    /// garment measurements.
    struct Item {
        var name: String
        var category: GarmentCategory
        var fit: FitStyle
        var leg: LegCut? = nil
        var material = "%100 Pamuk"
        var garmentChart = false
    }

    public static func products(for audience: GarmentAudience) -> [Product] {
        let items = audience == .women ? women : men
        return items.enumerated().compactMap { i, item in
            guard let spec = spec(item, audience: audience) else { return nil }
            return Product(key: "test-\(audience.rawValue)-\(i + 1)", name: item.name, brand: brand,
                           material: item.material, spec: spec)
        }
    }

    static let women: [Item] = [
        Item(name: "Beyaz Basic Tişört", category: .tshirt, fit: .regular),
        Item(name: "Siyah Crop Top", category: .tshirt, fit: .slim, material: "%95 Pamuk %5 Elastan"),
        Item(name: "Pembe Oversize Tişört", category: .tshirt, fit: .oversized),
        Item(name: "Bej Keten Gömlek", category: .shirt, fit: .relaxed, material: "%100 Keten"),
        Item(name: "Mavi Saten Bluz", category: .shirt, fit: .regular, material: "%100 Polyester"),
        Item(name: "Krem Triko Kazak", category: .sweater, fit: .relaxed, material: "%50 Yün %50 Akrilik"),
        Item(name: "Gri Kapüşonlu Sweatshirt", category: .sweater, fit: .oversized),
        Item(name: "Lacivert Blazer Ceket", category: .jacket, fit: .slim, material: "%68 Polyester %30 Viskon %2 Elastan"),
        Item(name: "Haki Trençkot", category: .coat, fit: .regular),
        Item(name: "Siyah Deri Ceket", category: .jacket, fit: .slim, material: "%100 Poliüretan"),
        Item(name: "Mavi Mom Jean", category: .pants, fit: .relaxed, leg: .tapered),
        Item(name: "Siyah Skinny Jean", category: .pants, fit: .slim, leg: .skinny, material: "%92 Pamuk %6 Polyester %2 Elastan"),
        Item(name: "Bej Palazzo Pantolon", category: .pants, fit: .relaxed, leg: .wide, material: "%100 Viskon"),
        Item(name: "Lacivert İspanyol Paça Pantolon", category: .pants, fit: .regular, leg: .flare, material: "%97 Pamuk %3 Elastan"),
        Item(name: "Gri Straight Fit Kumaş Pantolon", category: .pants, fit: .regular, leg: .straight, material: "%65 Polyester %35 Viskon"),
        Item(name: "Siyah Toparlayıcı Tayt", category: .pants, fit: .slim, leg: .skinny, material: "%80 Polyamid %20 Elastan"),
        Item(name: "Denim Şort", category: .shorts, fit: .regular),
        Item(name: "Bej Bermuda Şort", category: .shorts, fit: .relaxed, material: "%100 Keten"),
        Item(name: "Siyah Mini Etek", category: .skirt, fit: .slim, material: "%95 Polyester %5 Elastan"),
        Item(name: "Bordo Pileli Midi Etek", category: .skirt, fit: .relaxed, material: "%100 Polyester"),
        Item(name: "Siyah Kalem Elbise", category: .dress, fit: .slim, material: "%95 Viskon %5 Elastan"),
        Item(name: "Desenli Midi Elbise", category: .dress, fit: .relaxed, material: "%100 Viskon"),
        Item(name: "Beyaz Gömlek Elbise", category: .dress, fit: .regular),
        Item(name: "Kırmızı Saten Abiye", category: .dress, fit: .slim, material: "%100 Polyester"),
        Item(name: "Beyaz Oversize Gömlek", category: .shirt, fit: .oversized, garmentChart: true),
        Item(name: "Siyah Regular Fit Tişört", category: .tshirt, fit: .regular, garmentChart: true),
        Item(name: "Mavi Yüksek Bel Wide Leg Jean", category: .pants, fit: .relaxed, leg: .wide, garmentChart: true),
        Item(name: "Yeşil Slim Fit Bluz", category: .shirt, fit: .slim, material: "%97 Pamuk %3 Elastan", garmentChart: true),
        Item(name: "Kahverengi Kaban", category: .coat, fit: .regular, material: "%60 Yün %40 Polyester", garmentChart: true),
        Item(name: "Lila Hırka", category: .sweater, fit: .relaxed, material: "%100 Akrilik", garmentChart: true),
    ]

    static let men: [Item] = [
        Item(name: "Beyaz Basic Tişört", category: .tshirt, fit: .regular),
        Item(name: "Siyah Slim Fit Tişört", category: .tshirt, fit: .slim, material: "%95 Pamuk %5 Elastan"),
        Item(name: "Gri Oversize Tişört", category: .tshirt, fit: .oversized),
        Item(name: "Lacivert Polo Yaka Tişört", category: .tshirt, fit: .regular),
        Item(name: "Beyaz Slim Fit Gömlek", category: .shirt, fit: .slim, material: "%97 Pamuk %3 Elastan"),
        Item(name: "Mavi Oxford Gömlek", category: .shirt, fit: .regular),
        Item(name: "Bej Keten Gömlek", category: .shirt, fit: .relaxed, material: "%100 Keten"),
        Item(name: "Lacivert Triko Kazak", category: .sweater, fit: .regular, material: "%50 Yün %50 Akrilik"),
        Item(name: "Siyah Kapüşonlu Sweatshirt", category: .sweater, fit: .oversized),
        Item(name: "Antrasit Blazer Ceket", category: .jacket, fit: .slim, material: "%70 Polyester %28 Viskon %2 Elastan"),
        Item(name: "Haki Bomber Mont", category: .jacket, fit: .regular, material: "%100 Polyester"),
        Item(name: "Siyah Kaban", category: .coat, fit: .regular, material: "%60 Yün %40 Polyester"),
        Item(name: "Mavi Slim Fit Jean", category: .pants, fit: .slim, leg: .slim, material: "%98 Pamuk %2 Elastan"),
        Item(name: "Siyah Skinny Jean", category: .pants, fit: .slim, leg: .skinny, material: "%92 Pamuk %6 Polyester %2 Elastan"),
        Item(name: "Bej Straight Fit Chino", category: .pants, fit: .regular, leg: .straight, material: "%98 Pamuk %2 Elastan"),
        Item(name: "Gri Jogger Eşofman Altı", category: .pants, fit: .relaxed, leg: .tapered),
        Item(name: "Haki Kargo Pantolon", category: .pants, fit: .relaxed, leg: .straight),
        Item(name: "Lacivert Wide Leg Pantolon", category: .pants, fit: .relaxed, leg: .wide),
        Item(name: "Denim Şort", category: .shorts, fit: .regular),
        Item(name: "Bej Bermuda Şort", category: .shorts, fit: .relaxed, material: "%100 Keten"),
        Item(name: "Siyah Slim Fit Kumaş Pantolon", category: .pants, fit: .slim, leg: .slim, material: "%65 Polyester %33 Viskon %2 Elastan"),
        Item(name: "Kahverengi Deri Ceket", category: .jacket, fit: .slim, material: "%100 Poliüretan"),
        Item(name: "Yeşil Regular Fit Gömlek", category: .shirt, fit: .regular),
        Item(name: "Bordo Sweatshirt", category: .sweater, fit: .regular),
        Item(name: "Beyaz Boxy Fit Kalın Kumaş Tişört", category: .tshirt, fit: .oversized, garmentChart: true),
        Item(name: "Kahverengi Regular Fit Gömlek", category: .shirt, fit: .regular, garmentChart: true),
        Item(name: "Siyah Regular Fit Jean", category: .pants, fit: .regular, leg: .straight, garmentChart: true),
        Item(name: "Lacivert Slim Fit Takım Ceket", category: .jacket, fit: .slim, material: "%70 Yün %30 Polyester", garmentChart: true),
        Item(name: "Gri Regular Fit Sweatshirt", category: .sweater, fit: .regular, garmentChart: true),
        Item(name: "Mavi Straight Fit Jean", category: .pants, fit: .regular, leg: .straight, material: "%99 Pamuk %1 Elastan", garmentChart: true),
    ]

    static func labels(_ item: Item, audience: GarmentAudience) -> [String] {
        if item.category == .pants || item.category == .shorts {
            return audience == .men ? ["29", "30", "31", "32", "33", "34", "36"] : ["34", "36", "38", "40", "42"]
        }
        return ["XS", "S", "M", "L", "XL", "XXL"]
    }

    static func spec(_ item: Item, audience: GarmentAudience) -> GarmentSpec? {
        var info = ProductInfo()
        info.name = item.name
        info.category = item.category
        info.fitStyle = item.fit
        info.legCut = item.leg
        info.audience = audience
        info.material = item.material
        info.stretch = GarmentClassifier.stretch(fromComposition: item.material)
        info.availableSizes = labels(item, audience: audience)
        // The store's model, of average height: lengths for the sizes come from it.
        info.modelFit = ModelFit(size: "M", heightCm: audience == .men ? 178 : 165)
        guard let (standard, _) = ProductSpec.make(from: info, fallbackAudience: audience) else { return nil }
        guard item.garmentChart else { return standard }
        // The garment's own measurements: the body each size fits plus the cut's ease.
        var spec = standard
        spec.chartKind = .garment
        let topEase: Double = switch item.fit {
        case .slim: 7
        case .regular: 12
        case .relaxed: 19
        case .oversized: 30
        }
        let hipEase: Double = switch item.leg {
        case .skinny?: 2
        case .slim?: 4
        case .wide?, .flare?: 14
        default: 8
        }
        let outer: Double = item.category == .coat ? 6 : 0
        spec.sizes = standard.sizes.enumerated().map { i, size in
            var values: [GarmentDimension: MeasuredValue] = [:]
            func set(_ d: GarmentDimension, _ cm: Double) { values[d] = MeasuredValue(cm: cm.rounded(), uncertaintyCm: 1, source: .manual) }
            if item.category.isBottom {
                if let w = size.values[.waist]?.cm { set(.waist, w + 1) }
                if let h = size.values[.hip]?.cm { set(.hip, h + hipEase) }
                if let inseam = size.values[.inseam]?.cm { set(.inseam, inseam) }
            } else {
                guard let chest = size.values[.chest]?.cm else { return size }
                set(.chest, chest + topEase + outer)
                if let w = size.values[.waist]?.cm { set(.waist, w + topEase + outer + 2) }
                let shoulderShare = audience == .men ? 0.455 : 0.41
                set(.shoulderWidth, chest * shoulderShare + (item.fit == .oversized ? 6 : item.fit == .relaxed ? 2 : 0))
                // Back length as stores measure it: the torso a size suits plus the
                // kind's usual length below it, a size step longer each size up.
                let steps = Double(i - (standard.sizes.firstIndex { $0.label == "M" } ?? 2))
                let torso: Double = audience == .men ? 45 : 41
                let below: Double? = switch item.category {
                case .tshirt: 18
                case .shirt, .sweater: 21
                case .jacket: 25
                case .coat: 50
                default: nil
                }
                if let below { set(.bodyLength, torso + below + 1.5 * steps) }
                if let sleeve = size.values[.sleeveLength]?.cm { set(.sleeveLength, sleeve + 2.5) }
            }
            return SizeEntry(label: size.label, values: values)
        }
        return spec
    }
}
