import Foundation
import Testing
@testable import ProductMeasurementParser
import WearIQCore

/// The Turkish–English textile dictionary and what each number on a page is.
@Suite struct TextileDictionaryTests {
    @Test(arguments: [
        ("İç boy", GarmentDimension.inseam), ("İç dikiş", .inseam), ("Inseam", .inseam), ("Paça boyu", .inseam),
        ("Dış boy", .outseam), ("Outside leg", .outseam),
        ("Paça genişliği", .legOpening), ("Paça açıklığı", .legOpening), ("Leg opening", .legOpening),
        ("Paça", .legOpening), ("Paça (cm)", .legOpening),
        ("Ön ağ", .frontRise), ("Önden bel yüksekliği", .frontRise), ("Front rise", .frontRise), ("Rise", .frontRise),
        ("Bel", .waist), ("Basen", .hip), ("Uyluk", .thigh), ("Boy", .bodyLength),
    ])
    func headingMeans(_ heading: String, _ dimension: GarmentDimension) {
        #expect(SizeChartParser.dimension(for: SizeChartParser.fold(heading)) == dimension)
    }

    /// Headings that name a part but not one the app reads, and names of cuts.
    @Test(arguments: ["Arka ağ", "Back rise", "Arkadan bel yüksekliği", "Kol genişliği", "Boyun",
                      "Dar Paça Jean", "High Rise Skinny", "İspanyol Paça"])
    func headingIsNotAMeasurement(_ heading: String) {
        let dim = SizeChartParser.dimension(for: SizeChartParser.fold(heading))
        #expect(dim != .legOpening && dim != .frontRise && dim != .waist && dim != .bodyLength)
    }

    @Test func trouserChartWithLegOpeningAndRise() throws {
        let text = """
        Ürün ölçüleri (cm)
        Beden        S    M    L
        Bel          76   80   84
        İç boy       78   79   80
        Ön ağ        26   27   28
        Paça         17   18   19
        """
        let chart = SizeChartParser().parse(text)
        let m = try #require(chart.sizes.first { $0.label == "M" })
        #expect(m.values[.waist]?.cm == 80)
        #expect(m.values[.inseam]?.cm == 79)
        #expect(m.values[.frontRise]?.cm == 27)
        // 18 cm across the hem, laid flat: 36 cm round.
        #expect(m.values[.legOpening]?.cm == 36)
        #expect(chart.basis(for: .legOpening) == .flatLay)
        #expect(chart.basis(for: .waist) == .garment)
        #expect(chart.basis(for: .frontRise) == .garment)
        // The rise isn't the garment's length.
        #expect(m.values[.bodyLength] == nil)
    }

    @Test func bodyChartBasis() {
        let chart = SizeChartParser().parse("""
        Vücut ölçüleri (cm)
        Beden   S      M      L
        Bel     72-76  76-80  80-84
        """)
        #expect(chart.basis(for: .waist) == .body)
    }

    /// A table read without its title ("Ürün ölçüleri" above it): the title says what it is.
    @Test func kindStatedAroundTheTable() throws {
        let grid = [["Beden", "S", "M"], ["Bel", "76", "80"], ["İç boy", "78", "79"]]
        let chart = try #require(HTMLSizeTables.sections(fromGrid: grid).first).chart
        let stated = chart.kind(statedIn: "Ürün ölçüleri (cm)\nBeden S M")
        #expect(stated.kind == .garment)
        #expect(!stated.warnings.contains { if case .chartKindGuessed = $0 { true } else { false } })
        // Nothing said: the chart as it was.
        #expect(chart.kind(statedIn: "Beden tablosu") == chart)
    }

    // MARK: - Two values for one measurement

    @Test func twoWaistRowsSuspendTheWaistAndKeepTheInseam() throws {
        let text = """
        Ürün ölçüleri (cm)
        Beden    30   32   34
        Bel      76   81   86
        Bel      84   89   94
        İç boy   78   79   80
        """
        let chart = SizeChartParser().parse(text)
        #expect(chart.warnings.contains(.conflictingValuesSuspended(.waist)))
        let m = try #require(chart.sizes.first { $0.label == "32" })
        #expect(m.values[.waist] == nil)
        #expect(m.values[.inseam]?.cm == 79)
    }

    @Test func repeatedRowWithTheSameNumbersIsNoConflict() throws {
        let chart = SizeChartParser().parse("""
        Ürün ölçüleri (cm)
        Beden  S    M
        Bel    76   80
        Bel    76   80,5
        """)
        #expect(!chart.warnings.contains(.conflictingValuesSuspended(.waist)))
        #expect(chart.sizes.first?.values[.waist]?.cm == 76)
    }

    private func trouserTable(waists: [Double], inseams: [Double]) -> SizeChartSection {
        let sizes = zip(["30", "32", "34"], zip(waists, inseams)).map { label, v in
            SizeEntry(label: label, values: [.waist: MeasuredValue(cm: v.0, uncertaintyCm: 0.5, source: .manual),
                                             .inseam: MeasuredValue(cm: v.1, uncertaintyCm: 0.5, source: .manual)])
        }
        return SizeChartSection(title: nil, fitStyle: nil, chart: ParsedSizeChart(sizes: sizes, kind: .garment))
    }

    /// A trouser page with two tables for trousers and nothing saying which is this
    /// product's: the waist they disagree on is left out, the inseam they share stays.
    @Test func twoEquallyLikelyTablesSuspendWhatTheyDisagreeOn() throws {
        let a = trouserTable(waists: [76, 81, 86], inseams: [78, 79, 80])
        let b = trouserTable(waists: [84, 89, 94], inseams: [78, 79, 80])
        let chosen = try #require(SizeTableReader.best([a, b], fit: nil, category: .pants, audience: nil))
        #expect(chosen.chart.warnings.contains(.conflictingValuesSuspended(.waist)))
        #expect(chosen.chart.sizes.allSatisfy { $0.values[.waist] == nil })
        #expect(chosen.chart.sizes.first { $0.label == "32" }?.values[.inseam]?.cm == 79)
    }

    /// A T-shirt table on a trouser page is not a rival: the trousers' own is read whole.
    @Test func tableForAnotherGarmentIsNoRival() throws {
        let trousers = trouserTable(waists: [76, 81, 86], inseams: [78, 79, 80])
        let tee = SizeChartSection(title: "Tişört", fitStyle: nil, chart: ParsedSizeChart(sizes: [
            SizeEntry(label: "M", values: [.chest: MeasuredValue(cm: 104, uncertaintyCm: 0.5, source: .manual),
                                           .waist: MeasuredValue(cm: 98, uncertaintyCm: 0.5, source: .manual)]),
        ], kind: .garment))
        let chosen = try #require(SizeTableReader.best([tee, trousers], fit: nil, category: .pants, audience: nil))
        #expect(chosen.chart.warnings.isEmpty)
        #expect(chosen.chart.sizes.first { $0.label == "32" }?.values[.waist]?.cm == 81)
    }

    /// The product's fit names one of the tables: that one, whole.
    @Test func theProductsFitSettlesIt() throws {
        var slim = trouserTable(waists: [76, 81, 86], inseams: [78, 79, 80])
        slim.fitStyle = .slim
        var regular = trouserTable(waists: [84, 89, 94], inseams: [78, 79, 80])
        regular.fitStyle = .regular
        let chosen = try #require(SizeTableReader.best([slim, regular], fit: .regular, category: .pants, audience: nil))
        #expect(chosen.chart.sizes.first { $0.label == "32" }?.values[.waist]?.cm == 89)
        #expect(chosen.chart.warnings.isEmpty)
    }
}
