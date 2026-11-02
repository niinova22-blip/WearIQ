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

/// Women's trousers in EU sizes (34–44, most European and Turkish sites) are not waist
/// inches; jeans in W26–W32 are. Plus sizes have charts too.
@Suite struct StandardChartSizingSystems {
    @Test func womensEUTrousersAreNotInches() throws {
        let eu = try #require(StandardSizeCharts.chart(for: ["34", "36", "38", "40", "42"], category: .pants, audience: .women))
        let w38 = try #require(eu.sizes.first { $0.label == "38" }?.values[.waist]?.cm)
        #expect((68...74).contains(w38))
        let jeans = try #require(StandardSizeCharts.chart(for: ["26", "27", "28", "29", "30"], category: .pants, audience: .women))
        let w28 = try #require(jeans.sizes.first { $0.label == "28" }?.values[.waist]?.cm)
        #expect(abs(w28 - 71.1) < 1)
        let men = try #require(StandardSizeCharts.chart(for: ["32", "34", "36"], category: .pants, audience: .men))
        #expect(abs((men.sizes.first { $0.label == "34" }?.values[.waist]?.cm ?? 0) - 86.4) < 1)
    }

    @Test func plusSizesHaveCharts() throws {
        let women = try #require(StandardSizeCharts.chart(for: ["XL", "2XL", "3XL", "4XL", "5XL"], category: .dress, audience: .women))
        #expect(women.sizes.count == 5)
        let chests = women.sizes.compactMap { $0.values[.chest]?.cm }
        #expect(chests == chests.sorted() && chests.last! > 130)
        let men = try #require(StandardSizeCharts.chart(for: ["2XL", "3XL", "4XL", "5XL"], category: .tshirt, audience: .men))
        #expect(men.sizes.count == 4)
        let eu = try #require(StandardSizeCharts.chart(for: ["50", "52", "54", "56", "58"], category: .dress, audience: .women))
        #expect(eu.sizes.count == 5)
    }
}
