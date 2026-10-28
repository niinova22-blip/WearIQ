import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

@Suite struct HTMLSizeTablesTests {
    @Test func storeTableWithHalfChestAndShoulderSeam() throws {
        // Shape of a real store's product-page table: half chest, and "Omuz" meaning the
        // shoulder seam (about 10 cm), not the shoulder width.
        let html = """
        <table class="product-size-chart-info__table"><thead><tr><th></th><th>S</th><th>M</th><th>L</th></tr></thead>
        <tbody><tr><td>Boy</td><td>69</td><td>70</td><td>71</td></tr>
        <tr><td>G&ouml;ğ&uuml;s</td><td>56</td><td>58</td><td>60</td></tr>
        <tr><td>Kol Boyu</td><td>64.5</td><td>65</td><td>65.5</td></tr>
        <tr><td>Omuz</td><td>9.5</td><td>10</td><td>10</td></tr></tbody></table>
        <table><tr><td>Fiyat</td><td>899 TL</td></tr></table>
        """.replacingOccurrences(of: "&ouml;", with: "ö").replacingOccurrences(of: "&uuml;", with: "ü")
        let sections = HTMLSizeTables.sections(in: html)
        #expect(sections.count == 1)
        let chart = try #require(sections.first).chart
        let m = try #require(chart.sizes.first { $0.label == "M" })
        #expect(m.values[.chest]?.cm == 116)
        #expect(m.values[.sleeveLength]?.cm == 65)
        #expect(m.values[.bodyLength]?.cm == 70)
        #expect(m.values[.shoulderWidth] == nil)
        #expect(chart.kind == .garment)
        #expect(chart.warnings.contains(.implausibleColumnDropped(.shoulderWidth)))
    }

    @Test func sizesDownTheSide() throws {
        let html = "<table><tr><th>Beden</th><th>Bel</th><th>Kalça</th></tr><tr><td>30</td><td>78</td><td>96</td></tr><tr><td>32</td><td>83</td><td>100</td></tr></table>"
        let chart = try #require(HTMLSizeTables.sections(in: html).first).chart
        #expect(chart.sizes.map(\.label) == ["30", "32"])
        #expect(chart.sizes[1].values[.hip]?.cm == 100)
    }
}
