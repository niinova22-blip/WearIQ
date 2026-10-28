import Foundation
import WearIQCore

/// One table of a size chart image. Stores often put several in one image, one per fit
/// ("Slim Fit", "Regular Fit", "Oversize"), each titled in its top-left cell.
public struct SizeChartSection: Equatable, Sendable {
    public var title: String?
    /// Fit named in the title, if recognisable.
    public var fitStyle: FitStyle?
    public var chart: ParsedSizeChart
}

/// Reads size tables laid out with sizes in rows and measurements in columns:
///
///     Slim Fit   Göğüs  Bel  Omuz Genişliği  Kol Boyu
///     S          50     45   43              65
///     M          52     48   45              67
///
/// It works on OCR boxes rather than text lines, matching each number to the header cell
/// above it by horizontal position, so multi-line headers ("Omuz / Genişliği") and
/// columns we don't use (collar, hem) don't shift values into the wrong column.
public enum SizeTableReader {
    public static func sections(from boxes: [TextBox]) -> [SizeChartSection] {
        let fullText = SizeChartParser.fold(boxes.map(\.text).joined(separator: " "))
        var sections: [SizeChartSection] = []
        var header: [Column]?
        var title: String?
        var dataRows: [(label: String, cells: [TextBox])] = []
        // Rows seen since the last data row: the next table's header (possibly split
        // over several visual rows) plus titles and notes.
        var pending: [TextBox] = []

        func flush() {
            if let header, !dataRows.isEmpty,
               let chart = makeChart(header: header, rows: dataRows, fullText: fullText) {
                sections.append(SizeChartSection(title: title, fitStyle: title.flatMap(fitStyle), chart: chart))
            }
            dataRows = []
        }

        for row in groupRows(boxes) {
            guard let label = sizeLabel(row), row.dropFirst().contains(where: { SizeChartParser.value($0.text) != nil }) else {
                pending += row
                continue
            }
            if !pending.isEmpty {
                let cols = columns(pending)
                if cols.contains(where: { $0.dimension != nil }), cols.count >= 2 {
                    flush()
                    header = cols
                    title = titleText(pending, columns: cols)
                }
                pending = []
            }
            if header != nil { dataRows.append((label, Array(row.dropFirst()))) }
        }
        flush()
        return sections
    }

    /// The leftmost text level with the header cells, e.g. "Slim Fit (Dar kesim)".
    static func titleText(_ boxes: [TextBox], columns: [Column]) -> String? {
        let headerBoxes = columns.flatMap(\.boxes)
        guard let top = headerBoxes.map({ $0.midY - $0.height }).min(),
              let bottom = headerBoxes.map({ $0.midY + $0.height }).max(),
              let firstColumn = columns.map({ $0.centerX }).min() else { return nil }
        let candidates = boxes.filter { box in
            !headerBoxes.contains(box) && box.midY >= top && box.midY <= bottom && box.minX + box.width / 2 < firstColumn
        }.sorted { $0.minX < $1.minX }
        return candidates.isEmpty ? nil : candidates.map(\.text).joined(separator: " ")
    }

    /// Picks the table for the product's fit, or the only one.
    public static func best(_ sections: [SizeChartSection], fit: FitStyle?) -> SizeChartSection? {
        if let fit, let match = sections.first(where: { $0.fitStyle == fit }) { return match }
        return sections.count == 1 ? sections[0] : nil
    }

    // MARK: - Rows and columns

    struct Column: Equatable {
        var centerX: Double
        var dimension: GarmentDimension?
        var boxes: [TextBox]
    }

    static func groupRows(_ boxes: [TextBox]) -> [[TextBox]] {
        let sorted = boxes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.midY < $1.midY }
        var rows: [[TextBox]] = []
        for box in sorted {
            if let last = rows.last {
                let center = last.map(\.midY).reduce(0, +) / Double(last.count)
                let h = max(last.map(\.height).max() ?? 0, box.height)
                if abs(box.midY - center) < 0.5 * h {
                    rows[rows.count - 1].append(box)
                    continue
                }
            }
            rows.append([box])
        }
        return rows.map { $0.sorted { $0.minX < $1.minX } }
    }

    /// Words that head columns we read, plus columns we deliberately skip; both count
    /// as columns so that values stay aligned.
    private static let skippedColumns = ["etek", "yaka", "collar", "neck", "hem", "paca genisligi", "bilek", "kapanis"]

    static func columns(_ boxes: [TextBox]) -> [Column] {
        var cols: [Column] = []
        for box in boxes.sorted(by: { $0.minX < $1.minX }) {
            let folded = SizeChartParser.fold(box.text)
            let dim = SizeChartParser.dimension(for: folded)
            let skipped = skippedColumns.contains(where: folded.contains)
            let center = box.minX + box.width / 2
            // Continuation line of a header cell ("Genişliği" under "Omuz").
            if dim == nil, !skipped, let idx = cols.firstIndex(where: { abs($0.centerX - center) < max(box.width, 0.03) }) {
                cols[idx].boxes.append(box)
                continue
            }
            guard dim != nil || skipped else { continue }
            if let idx = cols.firstIndex(where: { abs($0.centerX - center) < max(box.width, 0.03) }) {
                if cols[idx].dimension == nil { cols[idx].dimension = dim }
                cols[idx].boxes.append(box)
            } else {
                cols.append(Column(centerX: center, dimension: dim, boxes: [box]))
            }
        }
        return cols.sorted { $0.centerX < $1.centerX }
    }

    static func sizeLabel(_ row: [TextBox]) -> String? {
        guard let first = row.first else { return nil }
        let t = first.text.trimmingCharacters(in: .whitespaces).uppercased()
        if SizeChartParser.letterSizes.contains(t) { return t }
        // Numeric sizes (EU 34–60, waist 26–44) followed by measurements.
        if let n = Int(t), (24...64).contains(n), row.count >= 3 { return t }
        return nil
    }

    static func fitStyle(_ title: String) -> FitStyle? {
        let t = SizeChartParser.fold(title)
        if t.contains("oversize") || t.contains("genis") { return .oversized }
        if t.contains("relax") || t.contains("bol") || t.contains("loose") { return .relaxed }
        if t.contains("slim") || t.contains("dar") || t.contains("skinny") { return .slim }
        if t.contains("regular") || t.contains("klasik") || t.contains("rlasik") || t.contains("normal") { return .regular }
        return nil
    }

    // MARK: - Values

    static func makeChart(header: [Column], rows: [(label: String, cells: [TextBox])], fullText: String) -> ParsedSizeChart? {
        var warnings: [ParsedSizeChart.Warning] = []
        var sizes: [SizeEntry] = []
        for row in rows {
            var values: [GarmentDimension: (mid: Double, halfRange: Double)] = [:]
            for cell in row.cells {
                guard let v = SizeChartParser.value(cell.text) else { continue }
                let center = cell.minX + cell.width / 2
                guard let col = header.min(by: { abs($0.centerX - center) < abs($1.centerX - center) }),
                      let dim = col.dimension else { continue }
                values[dim] = v
            }
            if !values.isEmpty {
                sizes.append(SizeEntry(label: row.label, values: values.mapValues {
                    MeasuredValue(cm: $0.mid, uncertaintyCm: max($0.halfRange, 0.5), source: .manual)
                }))
            }
        }
        guard !sizes.isEmpty else { return nil }

        let inch = SizeChartParser.containsAny(fullText, ["inch", "inches", "(in)"])
        if inch {
            sizes = sizes.map { s in
                SizeEntry(label: s.label, values: s.values.mapValues {
                    MeasuredValue(cm: $0.cm * 2.54, uncertaintyCm: $0.uncertaintyCm * 2.54, source: .manual)
                })
            }
        } else if !SizeChartParser.containsAny(fullText, ["cm", "santim"]) {
            warnings.append(.unitAssumedCentimetres)
        }

        var kind: SizeChartKind? = SizeChartParser.chartKind(fullText)
        // Flat-lay charts give half girths: a 52 cm "chest" can only be half of a garment.
        // One clearly halved girth means the whole table uses that convention.
        let limits: [(GarmentDimension, Double)] = [(.chest, 70), (.waist, 55), (.hip, 65), (.thigh, 40)]
        let isHalf = limits.contains { dim, limit in
            sizes.compactMap { $0.values[dim]?.cm }.max().map { $0 < limit } ?? false
        }
        if isHalf {
            for (dim, _) in limits where sizes.contains(where: { $0.values[dim] != nil }) {
                for i in sizes.indices {
                    if let v = sizes[i].values[dim] {
                        sizes[i].values[dim] = MeasuredValue(cm: v.cm * 2, uncertaintyCm: v.uncertaintyCm * 2, source: .manual)
                    }
                }
                warnings.append(.halfMeasurementsDoubled(dim))
            }
            kind = .garment
        }
        if kind == nil { warnings.append(.chartKindUnknown) }
        return ParsedSizeChart(sizes: sizes, kind: kind, unit: inch ? .inch : .cm, warnings: warnings)
    }
}
