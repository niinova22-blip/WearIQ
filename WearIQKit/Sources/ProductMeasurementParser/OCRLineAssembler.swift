import Foundation

/// One recognised text fragment. Normalised coordinates, y grows downwards.
public struct TextBox: Sendable, Equatable {
    public var text: String
    public var minX: Double
    public var midY: Double
    public var height: Double

    public init(text: String, minX: Double, midY: Double, height: Double) {
        self.text = text
        self.minX = minX
        self.midY = midY
        self.height = height
    }
}

/// OCR returns table cells as separate fragments in no useful order. This rebuilds
/// visual rows (fragments whose vertical centres are close) and orders each row left
/// to right, producing the line-per-row text `SizeChartParser` expects.
public enum OCRLineAssembler {
    public static func assemble(_ boxes: [TextBox]) -> String {
        let sorted = boxes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.midY < $1.midY }
        var rows: [[TextBox]] = []
        for box in sorted {
            if let last = rows.last, let ref = last.first,
               abs(box.midY - rowCenter(last)) < 0.5 * max(ref.height, box.height) {
                rows[rows.count - 1].append(box)
            } else {
                rows.append([box])
            }
        }
        return rows.map { row in
            row.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: "  ")
        }.joined(separator: "\n")
    }

    private static func rowCenter(_ row: [TextBox]) -> Double {
        row.map(\.midY).reduce(0, +) / Double(row.count)
    }
}
