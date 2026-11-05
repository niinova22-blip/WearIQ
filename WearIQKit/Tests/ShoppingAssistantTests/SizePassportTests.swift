import Testing
@testable import ShoppingAssistant
import WearIQCore

private func m(_ cm: Double) -> MeasuredValue { MeasuredValue(cm: cm, uncertaintyCm: 1, source: .scan) }

@Suite struct SizePassportTests {
    @Test func averageManIsAMediumOrLarge() {
        let body = BodyProfile(values: [.height: m(178), .chest: m(100), .waist: m(86), .hip: m(100), .inseam: m(81)], sex: .male)
        let lines = SizePassport.lines(for: body)
        let tee = lines.first { $0.category == .tshirt && $0.system == .letters }
        #expect(["M", "L"].contains(tee?.size ?? ""))
        let jeans = lines.first { $0.category == .pants && $0.system == .waistInches }
        #expect(["32", "33", "34"].contains(jeans?.size ?? ""))
    }

    @Test func womanGetsEuropeanNumbers() {
        let body = BodyProfile(values: [.height: m(165), .chest: m(88), .waist: m(70), .hip: m(96), .inseam: m(76)], sex: .female)
        let lines = SizePassport.lines(for: body)
        let dress = lines.first { $0.category == .dress && $0.system == .european }
        #expect(["36", "38", "40"].contains(dress?.size ?? ""))
    }

    @Test func brandsSideBySide() {
        let rows = SizePassport.compare([
            .init(brand: "Zara", category: .tshirt, size: "M", confirmed: false),
            .init(brand: "Nike", category: .tshirt, size: "L", confirmed: false),
            .init(brand: "zara ", category: .tshirt, size: "L", confirmed: true),
            .init(brand: "Mavi", category: .pants, size: "32", confirmed: false),
        ])
        #expect(rows.count == 1)
        let zara = rows[0].brands.first { $0.brand.lowercased().hasPrefix("zara") }
        #expect(zara?.size == "L")
        #expect(zara?.confirmed == true)
    }
}
