import Testing
@testable import ProductMeasurementParser
import WearIQCore

@Suite struct SizeChartParserTests {
    let parser = SizeChartParser()

    @Test func parsesTurkishGarmentChart() {
        let text = """
        Ürün ölçüleri (cm)
        Beden   S    M    L
        Göğüs   104  112  120
        Omuz    44   46,5 49
        Kol     63   65,5 68
        Boy     70   73   76
        """
        let r = parser.parse(text)
        #expect(r.kind == .garment)
        #expect(r.unit == .cm)
        #expect(r.sizes.map(\.label) == ["S", "M", "L"])
        #expect(r.sizes[1].values[.chest]?.cm == 112)
        #expect(r.sizes[1].values[.shoulderWidth]?.cm == 46.5)
        #expect(r.sizes[2].values[.sleeveLength]?.cm == 68)
        #expect(r.sizes[0].values[.bodyLength]?.cm == 70)
        #expect(r.warnings.isEmpty)
    }

    @Test func rangesBecomeMidpointWithUncertainty() {
        let text = """
        Body measurements (cm)
        Size  S      M       L
        Chest 88-92  96–100  104 - 108
        """
        let r = parser.parse(text)
        #expect(r.kind == .body)
        let m = r.sizes[1].values[.chest]!
        #expect(m.cm == 98)
        #expect(m.uncertaintyCm == 2)
        #expect(r.sizes[2].values[.chest]?.cm == 106)
    }

    @Test func convertsInches() {
        let text = """
        Size (inches)  S   M
        Waist          30  32
        Inseam         32  32
        """
        let r = parser.parse(text)
        #expect(r.unit == .inch)
        #expect(abs(r.sizes[0].values[.waist]!.cm - 76.2) < 0.001)
        #expect(abs(r.sizes[1].values[.inseam]!.cm - 81.28) < 0.001)
        // "Inseam" must not be mistaken for generic length.
        #expect(r.sizes[0].values[.bodyLength] == nil)
    }

    @Test func doublesHalfChestMeasurements() {
        let text = """
        Garment measurements cm
        Size        S   M
        1/2 Chest   52  56
        """
        let r = parser.parse(text)
        #expect(r.sizes[0].values[.chest]?.cm == 104)
        #expect(r.warnings.contains(.halfMeasurementsDoubled(.chest)))
    }

    @Test func numericSizesAndUnknownKindWarn() {
        let text = """
        Beden 38 40 42
        Bel 76 80 84
        Kalça 96 100 104
        """
        let r = parser.parse(text)
        #expect(r.sizes.map(\.label) == ["38", "40", "42"])
        #expect(r.sizes[2].values[.hip]?.cm == 104)
        #expect(r.kind == nil)
        #expect(r.warnings.contains(.chartKindUnknown))
        #expect(r.warnings.contains(.unitAssumedCentimetres))
    }

    @Test func flagsRowsWithWrongValueCount() {
        let text = """
        Ürün ölçüleri cm
        Beden S M L
        Göğüs 104 112
        """
        let r = parser.parse(text)
        #expect(r.sizes.isEmpty)
        #expect(r.warnings.contains(.rowValueCountMismatch(label: "Göğüs 104 112")))
    }

    @Test func emptyTextYieldsNoSizes() {
        #expect(parser.parse("").sizes.isEmpty)
    }
}
