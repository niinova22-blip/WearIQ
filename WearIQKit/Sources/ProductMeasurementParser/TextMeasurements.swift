import Foundation
import WearIQCore

/// Measurements a product page states in prose rather than a table: "M beden ürünün
/// iç boyu 78 cm, paça genişliği 17 cm". An on-device language model may propose what
/// each number is; nothing it says is taken on its word. Every number must be in the
/// text, every name must be in the textile dictionary, every size one the store sells.
public enum TextMeasurements {
    /// What the language model proposes for one number in the text.
    public struct Proposal: Equatable, Sendable {
        /// The size it is for, as written ("M", "32"); empty when the text names none.
        public var size: String
        /// The measurement's name as written ("İç boy", "Paça").
        public var name: String
        public var value: Double
        /// "cm" or "inch".
        public var unit: String
        /// "body", "garment", "flat" or "model".
        public var basis: String

        public init(size: String, name: String, value: Double, unit: String, basis: String) {
            self.size = size; self.name = name; self.value = value; self.unit = unit; self.basis = basis
        }
    }

    // MARK: - The text worth reading

    /// The sentences of a page's visible text that hold a number next to a measurement's
    /// name, at most `limit` characters: what the model is given (its context is small).
    public static func sentences(in visible: String, limit: Int = 1200) -> String? {
        // Sentences end at a full stop that isn't a decimal point ("17.5 cm", "1.86").
        let marked = visible.replacingOccurrences(of: #"(?<!\d)\.|\.(?!\d)"#, with: "\n", options: .regularExpression)
        let pieces = marked.components(separatedBy: CharacterSet(charactersIn: "\n;•|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var picked: [String] = []
        var length = 0
        for piece in pieces where piece.count >= 6 && piece.count <= 300 {
            let folded = SizeChartParser.fold(piece)
            guard folded.rangeOfCharacter(from: .decimalDigits) != nil,
                  folded.contains("cm") || folded.contains("inch") || folded.contains("olcu") || folded.contains("measure"),
                  measurementName(in: folded) else { continue }
            guard !picked.contains(piece), length + piece.count <= limit else { continue }
            picked.append(piece)
            length += piece.count + 2
        }
        return picked.isEmpty ? nil : picked.joined(separator: ". ")
    }

    /// Whether folded text names a measurement the app reads anywhere in it.
    static func measurementName(in folded: String) -> Bool {
        let words = ["gogus", "bel", "basen", "kalca", "uyluk", "ic boy", "ic bacak", "ic dikis", "dis boy", "paca",
                     "on ag", "omuz", "kol", "boy", "uzunluk", "chest", "waist", "hip", "thigh", "inseam", "outseam",
                     "leg opening", "rise", "shoulder", "sleeve", "length"]
        return words.contains { folded.contains($0) }
    }

    // MARK: - Checking the proposals

    /// The size chart the checked proposals make, or nil when too little survives. A
    /// chart of one size is only kept when the store sells no more than that one: one
    /// size among many would be every body's answer.
    public static func chart(from proposals: [Proposal], text: String, sizes: [String]) -> ParsedSizeChart? {
        let folded = SizeChartParser.fold(text)
        let inchText = SizeChartParser.containsAny(folded, ["inch", "inches", "\u{2033}", " in ", "\""])
        let known = Dictionary(sizes.map { ($0.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var values: [String: [GarmentDimension: MeasuredValue]] = [:]
        var bases: [MeasurementBasis] = []
        var halved = Set<GarmentDimension>()
        var conflicting = Set<GarmentDimension>()
        for p in proposals {
            // The model's own measurements say who wears the size, not what it measures.
            let basis = Self.basis(p.basis)
            guard basis != .model, p.value > 0 else { continue }
            guard let dim = SizeChartParser.dimension(for: SizeChartParser.fold(p.name)),
                  SizeChartParser.fold(text).contains(SizeChartParser.fold(p.name).trimmingCharacters(in: .whitespaces)),
                  appears(p.value, in: text) else { continue }
            let label = p.size.trimmingCharacters(in: .whitespaces).uppercased()
            let size: String
            if label.isEmpty {
                // Numbers for no size are for the only size there is, or for none.
                guard sizes.count == 1 else { continue }
                size = sizes[0]
            } else if let k = known[label] {
                size = k
            } else if sizes.isEmpty, appears(label: label, in: text) {
                size = label
            } else { continue }
            let inch = p.unit.lowercased().hasPrefix("in") && inchText
            var cm = p.value * (inch ? 2.54 : 1)
            if basis == .flatLay, dim.isGirth {
                cm *= 2
                halved.insert(dim)
            }
            let value = MeasuredValue(cm: cm, uncertaintyCm: inch ? 1.27 : 0.5, source: .manual)
            if let earlier = values[size]?[dim], SizeChartParser.differs(earlier, value) { conflicting.insert(dim) }
            values[size, default: [:]][dim] = value
            if let basis { bases.append(basis) }
        }
        let entries = SizeOrder.sorted(values.map { SizeEntry(label: $0.key, values: $0.value) })
        guard !entries.isEmpty, entries.count >= 2 || sizes.count <= 1 else { return nil }
        // What the numbers are: what the text says outright first, then the model's word
        // when every number agrees; otherwise unknown, and the user is asked.
        var kind = SizeChartParser.chartKind(folded)
        if kind == nil {
            let garmentLike = bases.allSatisfy { $0 == .garment || $0 == .flatLay }
            if !bases.isEmpty, garmentLike { kind = .garment }
            if !bases.isEmpty, bases.allSatisfy({ $0 == .body }) { kind = .body }
        }
        var warnings: [ParsedSizeChart.Warning] = halved.sorted { $0.rawValue < $1.rawValue }.map { .halfMeasurementsDoubled($0) }
        if kind == nil { warnings.append(.chartKindUnknown) }
        return ParsedSizeChart(sizes: entries, kind: kind, unit: inchText ? .inch : .cm, warnings: warnings)
            .suspending(conflicting).plausibilityChecked()
    }

    static func basis(_ word: String) -> MeasurementBasis? {
        switch word.lowercased() {
        case "body": .body
        case "garment": .garment
        case "flat", "flatlay", "flat-lay": .flatLay
        case "model": .model
        default: nil
        }
    }

    /// Whether the number is written in the text: 78, 78.5 or 78,5, not as part of 178.
    static func appears(_ value: Double, in text: String) -> Bool {
        let whole = value.rounded() == value
        let digits = whole ? String(Int(value)) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: "[.,]")
        let pattern = "(?<![\\d.,])" + digits + (whole ? "(?![\\d]|[.,]\\d)" : "0*(?!\\d)")
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether a size label is written in the text as a word of its own.
    static func appears(label: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        return text.range(of: "(?<![\\p{L}\\d])" + escaped + "(?![\\p{L}\\d])", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
