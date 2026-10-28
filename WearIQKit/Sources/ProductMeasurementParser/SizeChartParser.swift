import Foundation
import WearIQCore

/// Result of reading a size chart from OCR text. Anything uncertain is surfaced in
/// `warnings` so the UI can ask the user to confirm instead of guessing silently.
public struct ParsedSizeChart: Equatable, Sendable {
    public var sizes: [SizeEntry]
    /// `nil` when the text doesn't say whether these are body or garment measurements.
    public var kind: SizeChartKind?
    public var unit: Unit
    public var warnings: [Warning]

    public enum Unit: String, Equatable, Sendable { case cm, inch }

    public enum Warning: Equatable, Sendable {
        case unitAssumedCentimetres
        case chartKindUnknown
        case halfMeasurementsDoubled(GarmentDimension)
        case rowValueCountMismatch(label: String)
        case unrecognisedRow(String)
        /// A column whose values can't be that measurement (e.g. shoulder seam length
        /// labelled "Omuz") was dropped.
        case implausibleColumnDropped(GarmentDimension)
    }
}

extension ParsedSizeChart {
    /// Store charts follow different conventions; this normalises the common ones.
    /// - Flat-lay charts give half girths: a 52 cm "chest" can only be half of a garment,
    ///   and one clearly halved girth means the whole table uses that convention.
    /// - Widths that no adult garment has are a different measurement under the same name.
    public func plausibilityChecked() -> ParsedSizeChart {
        var chart = self
        let limits: [(GarmentDimension, Double)] = [(.chest, 70), (.waist, 55), (.hip, 65), (.thigh, 40)]
        let isHalf = limits.contains { dim, limit in
            chart.sizes.compactMap { $0.values[dim]?.cm }.max().map { $0 < limit } ?? false
        }
        if isHalf {
            for (dim, _) in limits where chart.sizes.contains(where: { $0.values[dim] != nil }) {
                for i in chart.sizes.indices {
                    if let v = chart.sizes[i].values[dim] {
                        chart.sizes[i].values[dim] = MeasuredValue(cm: v.cm * 2, uncertaintyCm: v.uncertaintyCm * 2, source: v.source)
                    }
                }
                chart.warnings.append(.halfMeasurementsDoubled(dim))
            }
            chart.kind = .garment
            chart.warnings.removeAll { $0 == .chartKindUnknown }
        }
        let minimum: [GarmentDimension: Double] = [.shoulderWidth: 25, .sleeveLength: 15, .bodyLength: 30, .inseam: 30, .outseam: 50]
        for (dim, min) in minimum {
            let vals = chart.sizes.compactMap { $0.values[dim]?.cm }
            guard let maxVal = vals.max(), maxVal < min else { continue }
            for i in chart.sizes.indices { chart.sizes[i].values[dim] = nil }
            chart.warnings.append(.implausibleColumnDropped(dim))
        }
        chart.sizes.removeAll { $0.values.isEmpty }
        return chart
    }
}

/// Parses the tabular text OCR returns for size charts, e.g.
///
///     Beden   S    M    L
///     Göğüs   96   100  104
///     Bel     80-84 84-88 88-92
///
/// Supports Turkish and English labels, cm/inch, ranges ("96-100" → midpoint ± half
/// range), decimal commas and half (flat-lay) measurements.
public struct SizeChartParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> ParsedSizeChart {
        let lower = Self.fold(text)
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }

        var unit: ParsedSizeChart.Unit = .cm
        var warnings: [ParsedSizeChart.Warning] = []
        if Self.containsAny(lower, ["inch", "inches", " in)", "(in", "\""]) {
            unit = .inch
        } else if !Self.containsAny(lower, ["cm", "santim"]) {
            warnings.append(.unitAssumedCentimetres)
        }

        let kind = Self.chartKind(lower)
        if kind == nil { warnings.append(.chartKindUnknown) }

        var sizeLabels: [String] = []
        var columns: [[GarmentDimension: MeasuredValue]] = []

        for line in lines {
            let tokens = Self.tokens(line)
            guard !tokens.isEmpty else { continue }

            if sizeLabels.isEmpty, let labels = Self.sizeHeader(tokens) {
                sizeLabels = labels
                columns = Array(repeating: [:], count: labels.count)
                continue
            }
            guard !sizeLabels.isEmpty else { continue }

            let lineLower = Self.fold(line)
            guard let dim = Self.dimension(for: lineLower) else {
                if tokens.contains(where: { Self.number($0) != nil }) { warnings.append(.unrecognisedRow(line)) }
                continue
            }
            var values = tokens.compactMap(Self.value)
            // Labels like "1/2 Göğüs" produce a stray value; drop leading extras.
            if values.count > sizeLabels.count { values = Array(values.suffix(sizeLabels.count)) }
            guard values.count == sizeLabels.count else {
                warnings.append(.rowValueCountMismatch(label: line))
                continue
            }

            let isHalf = Self.containsAny(lineLower, ["1/2", "½", "yarim", "half", "across", "en "]) && Self.isGirth(dim)
            if isHalf { warnings.append(.halfMeasurementsDoubled(dim)) }
            let factor = (unit == .inch ? 2.54 : 1) * (isHalf ? 2 : 1)

            for (i, v) in values.enumerated() {
                columns[i][dim] = MeasuredValue(cm: v.mid * factor,
                                                uncertaintyCm: max(v.halfRange * factor, 0.5 * factor),
                                                source: .manual)
            }
        }

        let sizes = zip(sizeLabels, columns).compactMap { label, vals in
            vals.isEmpty ? nil : SizeEntry(label: label, values: vals)
        }
        return ParsedSizeChart(sizes: sizes, kind: kind, unit: unit, warnings: warnings).plausibilityChecked()
    }

    /// Whether folded chart text says the values are body or garment measurements.
    static func chartKind(_ folded: String) -> SizeChartKind? {
        if containsAny(folded, ["vucut olc", "body measure", "beden olculeri", "to fit", "fits body"]) { return .body }
        if containsAny(folded, ["urun olc", "garment", "product measure", "flat", "duz olc", "giysi olc"]) { return .garment }
        return nil
    }

    // MARK: - Tokenising

    static func tokens(_ line: String) -> [String] {
        // Normalise en/em dashes and "to" so ranges become a single token.
        var s = line.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        s = s.replacingOccurrences(of: #"(\d)\s*-\s*(\d)"#, with: "$1-$2", options: .regularExpression)
        return s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "|" || $0 == ";" }).map(String.init)
    }

    static let letterSizes: Set<String> = ["XXXS", "XXS", "XS", "S", "M", "L", "XL", "XXL", "XXXL", "2XL", "3XL", "4XL", "5XL"]

    /// A header row is mostly size labels (letter sizes or EU/waist numbers).
    static func sizeHeader(_ tokens: [String]) -> [String]? {
        let upper = tokens.map { $0.uppercased() }
        let letters = upper.filter { letterSizes.contains($0) }
        if letters.count >= 2 { return letters }
        let lower = tokens.first.map(fold) ?? ""
        let headerWords = ["beden", "size", "eu", "boyut", "numara"]
        if headerWords.contains(where: lower.hasPrefix) {
            let rest = tokens.dropFirst().filter { Int($0) != nil || $0.contains("/") }
            if rest.count >= 2 { return rest.map { $0 } }
        }
        return nil
    }

    private static let labelMap: [(GarmentDimension, [String])] = [
        (.shoulderWidth, ["omuz", "shoulder"]),
        (.sleeveLength, ["kol", "sleeve"]),
        (.chest, ["gogus", "chest", "bust"]),
        (.waist, ["bel", "waist"]),
        (.hip, ["kalca", "hip", "seat"]),
        (.thigh, ["uyluk", "baldir", "thigh"]),
        (.inseam, ["ic bacak", "inseam", "inside leg", "paca boyu"]),
        (.outseam, ["dis bacak", "outseam", "outside leg"]),
        (.bodyLength, ["boy", "length", "uzunluk"]),
    ]

    /// Order matters: "iç bacak" must win over the generic "boy"/"length".
    /// Rows that name a body part but measure something we don't use (sleeve or leg
    /// opening width, back width); without this "Kol genişliği" would be read as sleeve length.
    private static let notMeasured = ["kol genis", "sleeve width", "bicep", "pazu", "paca genis", "leg opening",
                                      "etek genis", "bilek", "sirt genis", "back width", "yaka"]

    static func dimension(for line: String) -> GarmentDimension? {
        if notMeasured.contains(where: line.contains) { return nil }
        for (dim, keys) in [labelMap[6], labelMap[7]] + labelMap where keys.contains(where: line.contains) {
            // "Boy" alone in a height-based chart means body height, which we don't map.
            if dim == .bodyLength, line.contains("vucut boyu") || line.contains("height") { return nil }
            return dim
        }
        return nil
    }

    /// Case- and diacritic-insensitive form that treats Turkish İ/ı like i, so
    /// "GÖĞÜS", "göğüs" and "Inseam" all match plain ASCII keys.
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func isGirth(_ d: GarmentDimension) -> Bool {
        [.chest, .waist, .hip, .thigh].contains(d)
    }

    static func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: CharacterSet(charactersIn: "\"cm")))
    }

    static func value(_ token: String) -> (mid: Double, halfRange: Double)? {
        let parts = token.split(separator: "-").map(String.init)
        if parts.count == 2, let a = number(parts[0]), let b = number(parts[1]), b >= a {
            return ((a + b) / 2, (b - a) / 2)
        }
        if parts.count == 1, let v = number(parts[0]), v > 0 { return (v, 0) }
        return nil
    }

    static func containsAny(_ s: String, _ needles: [String]) -> Bool {
        needles.contains(where: s.contains)
    }
}
