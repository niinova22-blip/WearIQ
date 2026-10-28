import Foundation

/// Size charts some stores publish as plain HTML tables in the product page.
/// Each table is turned into a grid of pseudo OCR boxes so the same readers handle
/// both layouts (sizes across the top, or sizes down the side).
public enum HTMLSizeTables {
    public static func sections(in html: String) -> [SizeChartSection] {
        tables(in: html).flatMap(sections(fromGrid:))
    }

    static func sections(fromGrid grid: [[String]]) -> [SizeChartSection] {
        let text = SizeChartParser.fold(grid.joined().joined(separator: " "))
        // Only tables that talk about body/garment dimensions; skips price tables etc.
        guard grid.count >= 2, grid.contains(where: { row in row.contains { SizeChartParser.dimension(for: SizeChartParser.fold($0)) != nil } }),
              text.rangeOfCharacter(from: .decimalDigits) != nil else { return [] }

        var boxes: [TextBox] = []
        for (r, row) in grid.enumerated() {
            for (c, cell) in row.enumerated() where !cell.isEmpty {
                boxes.append(TextBox(text: cell, minX: 0.01 + Double(c) * 0.1, midY: 0.025 + Double(r) * 0.05,
                                     height: 0.03, width: 0.08))
            }
        }
        let rowsFirst = SizeTableReader.sections(from: boxes)
        if !rowsFirst.isEmpty { return rowsFirst }
        let chart = SizeChartParser().parse(grid.map { $0.joined(separator: "  ") }.joined(separator: "\n"))
        return chart.sizes.isEmpty ? [] : [SizeChartSection(title: nil, fitStyle: nil, chart: chart)]
    }

    static func tables(in html: String) -> [[[String]]] {
        matches(#"<table\b[^>]*>(.*?)</table>"#, in: html).map { table in
            matches(#"<tr\b[^>]*>(.*?)</tr>"#, in: table).map { row in
                matches(#"<t[hd]\b[^>]*>(.*?)</t[hd]>"#, in: row).map(cellText)
            }.filter { !$0.isEmpty }
        }
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func cellText(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
