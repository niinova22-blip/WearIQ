import FitEngine
import ProductMeasurementParser
import Testing
@testable import ShoppingAssistant
import WearIQCore

/// The testers' panel's products: thirty each, every kind of garment, and sized for an
/// average woman and man the way real pages are.
@Suite struct TestCatalogTests {
    static let woman = BodyProfile(values: [
        .height: .manual(165), .chest: .manual(88), .waist: .manual(71), .hip: .manual(97), .thigh: .manual(56),
        .shoulderWidth: .manual(37), .armLength: .manual(56), .torsoLength: .manual(41), .inseam: .manual(76),
    ], weightKg: 59, sex: .female)
    static let man = BodyProfile(values: [
        .height: .manual(178), .chest: .manual(99), .waist: .manual(86), .hip: .manual(99), .thigh: .manual(57),
        .shoulderWidth: .manual(45), .armLength: .manual(60), .torsoLength: .manual(45), .inseam: .manual(82),
    ], weightKg: 77, sex: .male)

    @Test(arguments: [GarmentAudience.women, .men])
    func thirtyOfEveryKind(_ audience: GarmentAudience) {
        let products = TestCatalog.products(for: audience)
        #expect(products.count == 30)
        #expect(Set(products.map(\.key)).count == 30)
        let kinds = Set(products.map(\.spec.category))
        let expected: Set<GarmentCategory> = audience == .women
            ? [.tshirt, .shirt, .sweater, .jacket, .coat, .pants, .shorts, .skirt, .dress]
            : [.tshirt, .shirt, .sweater, .jacket, .coat, .pants, .shorts]
        #expect(kinds == expected)
        #expect(products.filter { $0.spec.chartKind == .garment }.count == 6)
        // Every leg cut the avatar draws.
        #expect(Set(products.compactMap(\.spec.legCut)).count >= 4)
    }

    @Test(arguments: [GarmentAudience.women, .men])
    func everyProductGetsASize(_ audience: GarmentAudience) {
        let body = audience == .women ? Self.woman : Self.man
        var sizes: [String: Int] = [:]
        for product in TestCatalog.products(for: audience) {
            let analysis = FitEngine().analyze(body: body, garment: product.spec, preference: .asDesigned)
            // A size, or two to choose between: never "the chart can't tell".
            let size: String? = switch analysis.recommendation {
            case let .size(label, _): label
            case let .between(smaller, larger): smaller + "/" + larger
            case .insufficientData: nil
            }
            #expect(size != nil, "\(product.name): \(analysis.recommendation)")
            sizes[size ?? "-", default: 0] += 1
        }
        // An average body is mostly a medium.
        print(audience, sizes.sorted { $0.key < $1.key })
    }
}
