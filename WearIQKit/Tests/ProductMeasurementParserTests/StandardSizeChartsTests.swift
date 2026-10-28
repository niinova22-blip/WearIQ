import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

@Suite struct StandardSizeChartsTests {
    @Test func mensLetterSizes() throws {
        let chart = try #require(StandardSizeCharts.chart(for: ["S", "M", "L", "XL"], category: .jacket, audience: .men))
        #expect(chart.kind == .body)
        #expect(chart.warnings == [.standardChartUsed])
        #expect(chart.sizes.first { $0.label == "M" }?.values[.chest]?.cm == 100)
        #expect(chart.sizes.first { $0.label == "L" }?.values[.waist]?.cm == 96)
    }

    @Test func womensSizesAreSmaller() throws {
        let men = try #require(StandardSizeCharts.chart(for: ["M"], category: .shirt, audience: .men))
        let women = try #require(StandardSizeCharts.chart(for: ["M"], category: .shirt, audience: .women))
        #expect(try #require(women.sizes[0].values[.chest]).cm < (try #require(men.sizes[0].values[.chest]).cm) - 5)
    }

    @Test func numericSizes() throws {
        let jeans = try #require(StandardSizeCharts.chart(for: ["30", "32"], category: .pants, audience: .men))
        #expect(abs((jeans.sizes[1].values[.waist]?.cm ?? 0) - 81.3) < 0.1)
        #expect(jeans.sizes[0].values[.chest] == nil)
        let euMen = try #require(StandardSizeCharts.chart(for: ["50"], category: .jacket, audience: .men))
        #expect(euMen.sizes[0].values[.chest]?.cm == 100)
        let euWomen = try #require(StandardSizeCharts.chart(for: ["38"], category: .shirt, audience: .women))
        #expect(euWomen.sizes[0].values[.chest]?.cm == 88)
    }

    @Test func unknownLabelsGiveNothing() {
        #expect(StandardSizeCharts.chart(for: ["Standart", "TEK EBAT"], category: .shirt, audience: .men) == nil)
    }

    @Test func audienceFromText() {
        #expect(GarmentClassifier.audience(from: "Erkek Slim Fit Gömlek") == .men)
        #expect(GarmentClassifier.audience(from: "Kadın Oversize Ceket") == .women)
        #expect(GarmentClassifier.audience(from: "/tr/tr/woman-jackets-l1114.html") == .women)
        #expect(GarmentClassifier.audience(from: "Yünlü Regular Fit Ceket") == nil)
    }
}
