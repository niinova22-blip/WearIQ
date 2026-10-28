import Testing
@testable import ProductMeasurementParser

@Suite struct OCRLineAssemblerTests {
    @Test func rebuildsTableRowsFromShuffledCells() {
        // Cells as OCR might return them: column-wise and slightly misaligned.
        let boxes = [
            TextBox(text: "Beden", minX: 0.05, midY: 0.101, height: 0.03),
            TextBox(text: "Göğüs", minX: 0.05, midY: 0.152, height: 0.03),
            TextBox(text: "M", minX: 0.55, midY: 0.098, height: 0.03),
            TextBox(text: "104", minX: 0.30, midY: 0.149, height: 0.03),
            TextBox(text: "S", minX: 0.30, midY: 0.100, height: 0.03),
            TextBox(text: "112", minX: 0.55, midY: 0.155, height: 0.03),
            TextBox(text: " ", minX: 0.9, midY: 0.5, height: 0.03),
        ]
        let text = OCRLineAssembler.assemble(boxes)
        #expect(text == "Beden  S  M\nGöğüs  104  112")

        let chart = SizeChartParser().parse(text)
        #expect(chart.sizes.map(\.label) == ["S", "M"])
        #expect(chart.sizes[1].values[.chest]?.cm == 112)
    }

    @Test func separatesCloseButDistinctRows() {
        let boxes = [
            TextBox(text: "a", minX: 0, midY: 0.10, height: 0.02),
            TextBox(text: "b", minX: 0, midY: 0.125, height: 0.02),
        ]
        #expect(OCRLineAssembler.assemble(boxes) == "a\nb")
    }

    @Test func emptyInput() {
        #expect(OCRLineAssembler.assemble([]) == "")
    }
}
