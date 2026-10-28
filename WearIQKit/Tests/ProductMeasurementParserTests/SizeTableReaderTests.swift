import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// Layout modelled on a real marketplace shirt chart (1511×1600 px): three tables, sizes
/// in rows, half (flat-lay) girths, a two-line "Omuz / Genişliği" header and two columns
/// (hem, collar) the app doesn't use.
@Suite struct SizeTableReaderTests {
    private let w = 1511.0, h = 1600.0
    private let columnX: [Double] = [456, 642, 828, 1013, 1199, 1385]

    private func box(_ text: String, x: Double, y: Double, width: Double = 60) -> TextBox {
        TextBox(text: text, minX: (x - width / 2) / w, midY: y / h, height: 30 / h, width: width / w)
    }

    private func table(title: String, top: Double, rows: [(String, [Int])]) -> [TextBox] {
        var boxes = [
            box(title, x: 197, y: top, width: 280),
            box("Göğüs", x: columnX[0], y: top, width: 80), box("Bel", x: columnX[1], y: top, width: 40),
            box("Etek", x: columnX[2], y: top, width: 50),
            box("Omuz", x: columnX[3], y: top - 15, width: 70), box("Genişliği", x: columnX[3], y: top + 16, width: 100),
            box("Kol Boyu", x: columnX[4], y: top, width: 100), box("Yaka", x: columnX[5], y: top, width: 50),
        ]
        for (i, (label, values)) in rows.enumerated() {
            let y = top + 60 * Double(i + 1)
            boxes.append(box(label, x: 197, y: y, width: 70))
            for (j, v) in values.enumerated() { boxes.append(box(String(v), x: columnX[j], y: y, width: 36)) }
        }
        return boxes
    }

    private var chartBoxes: [TextBox] {
        [box("ERKEK GÖMLEK", x: 440, y: 125, width: 400)]
            + table(title: "Slim Fit (Dar kesim)", top: 302, rows: [
                ("XS", [47, 42, 47, 42, 64, 36]), ("S", [50, 45, 50, 43, 65, 38]), ("M", [52, 48, 53, 45, 67, 40]),
                ("L", [56, 51, 56, 46, 68, 42]), ("XL", [59, 55, 58, 49, 69, 44]), ("XXL", [62, 59, 61, 51, 70, 46]),
            ])
            + table(title: "Regular Fit (Rlasik kesim)", top: 784, rows: [
                ("M", [56, 56, 56, 48, 66, 38]), ("L", [58, 58, 58, 50, 67, 42]),
                ("XL", [61, 61, 61, 52, 68, 44]), ("2XL", [63, 63, 64, 54, 68, 46]),
            ])
            + table(title: "Oversize (Geniş kesim)", top: 1146, rows: [
                ("XS", [55, 56, 56, 48, 60, 38]), ("S", [57, 58, 58, 50, 61, 40]), ("M", [59, 60, 60, 52, 62, 42]),
            ])
            + [box("*Ölçüler üretime bağlı ±1 cm değişiklik gösterebilir.", x: 265, y: 1565, width: 470)]
    }

    @Test func readsThreeSectionsWithFits() {
        let sections = SizeTableReader.sections(from: chartBoxes)
        #expect(sections.count == 3)
        #expect(sections.map(\.fitStyle) == [.slim, .regular, .oversized])
        #expect(sections.map { $0.chart.sizes.count } == [6, 4, 3])
    }

    @Test func mapsColumnsAndDoublesHalfGirths() throws {
        let slim = try #require(SizeTableReader.best(SizeTableReader.sections(from: chartBoxes), fit: .slim))
        let m = try #require(slim.chart.sizes.first { $0.label == "M" })
        #expect(m.values[.chest]?.cm == 104)          // 52 flat → 104 around
        #expect(m.values[.waist]?.cm == 96)
        #expect(m.values[.shoulderWidth]?.cm == 45)   // widths are not doubled
        #expect(m.values[.sleeveLength]?.cm == 67)
        #expect(m.values.count == 4)                  // hem and collar ignored
        #expect(slim.chart.kind == .garment)
        #expect(slim.chart.warnings.contains(.halfMeasurementsDoubled(.chest)))
    }

    @Test func picksNothingWhenFitIsUnknownAndThereAreSeveral() {
        let sections = SizeTableReader.sections(from: chartBoxes)
        #expect(SizeTableReader.best(sections, fit: nil) == nil)
        #expect(SizeTableReader.best(Array(sections.prefix(1)), fit: nil) != nil)
    }

    @Test func fullCircumferenceChartIsNotDoubled() throws {
        let boxes = [
            box("Beden", x: 197, y: 100), box("Göğüs", x: columnX[0], y: 100), box("Bel", x: columnX[1], y: 100),
            box("S", x: 197, y: 160), box("96", x: columnX[0], y: 160), box("80", x: columnX[1], y: 160),
            box("M", x: 197, y: 220), box("100", x: columnX[0], y: 220), box("84", x: columnX[1], y: 220),
        ]
        let section = try #require(SizeTableReader.sections(from: boxes).first)
        #expect(section.chart.sizes[1].values[.chest]?.cm == 100)
        #expect(!section.chart.warnings.contains(.halfMeasurementsDoubled(.chest)))
    }
}
