import Foundation

/// What a product page says about the model wearing the garment. Stores write this in
/// many ways, for example:
///
///     Modelin Ölçüleri M Beden - 1,90cm - 100/84/101
///     Manken Ölçüleri Boy: 188 cm Göğüs: 100 cm - Bel: 84 cm - Kalça: 96 cm. Mankenin üzerindeki ürün M bedendir.
///     Mankenimiz 1.85 boyunda, göğüs ölçüsü 95 cm, bel 75 cm, basen 95 cm. Üzerinde M beden var.
///     Model: 187 cm, 92-76-98, beden L
///     The model is 6'1" and wears a size M. Chest 38", waist 31"
///
/// Convention in compact triplets ("100/84/101", "90-60-90"): chest/bust, waist, hip.
/// The size the model wears fits those body measurements, which anchors a size chart.
public struct ModelFit: Equatable, Sendable {
    public var size: String?
    public var heightCm: Double?
    public var chestCm: Double?
    public var waistCm: Double?
    public var hipCm: Double?

    public init(size: String? = nil, heightCm: Double? = nil, chestCm: Double? = nil, waistCm: Double? = nil, hipCm: Double? = nil) {
        self.size = size
        self.heightCm = heightCm
        self.chestCm = chestCm
        self.waistCm = waistCm
        self.hipCm = hipCm
    }

    /// Usable as a chart anchor: the worn size plus at least one girth.
    public var isAnchor: Bool { size != nil && (chestCm != nil || waistCm != nil || hipCm != nil) }

    fileprivate var fieldCount: Int {
        [size != nil, heightCm != nil, chestCm != nil, waistCm != nil, hipCm != nil].filter { $0 }.count
    }
}

public enum ModelFitParser {
    static let chestRange: ClosedRange<Double> = 70...140
    static let waistRange: ClosedRange<Double> = 50...130
    static let hipRange: ClosedRange<Double> = 70...145
    static let heightRange: ClosedRange<Double> = 140...210

    public static func parse(_ text: String) -> ModelFit? {
        let t = normalize(text)
        // Only look near a mention of the model, so the store's general size advice
        // ("chest 95 cm fits M") isn't taken for the model's measurements.
        let anchors = matches(#"\b(manken\w*|model\w*|the model)\b"#, in: t)
        var best: ModelFit?
        for anchor in anchors {
            let window = slice(t, around: anchor, before: 60, after: 260)
            let fit = parseWindow(window)
            if fit.fieldCount > (best?.fieldCount ?? 0) { best = fit }
        }
        return best
    }

    // MARK: - Window parsing

    static func parseWindow(_ w: String) -> ModelFit {
        var fit = ModelFit()
        let inches = w.contains("\"") || w.contains(" inch") || w.contains(" in.")

        // Labelled girths: "göğüs: 100", "gogus olcusu 95 cm", "bust 34\"", "kalça/basen".
        func labelled(_ labels: String, _ range: ClosedRange<Double>) -> Double? {
            guard let m = firstMatch(#"\b(?:"# + labels + #")\b(?:\s*(?:olcusu|cevresi|ölçüsü))?\s*[:=]?\s*(\d{2,3}(?:\.\d)?)\s*(cm|"|inch)?"#, in: w),
                  var v = Double(m[1]) else { return nil }
            if m[2] == "\"" || m[2] == "inch" || (m[2].isEmpty && inches && v < 60) { v *= 2.54 }
            return range.contains(v) ? v : nil
        }
        fit.chestCm = labelled("gogus|chest|bust|bust/chest", chestRange)
        fit.waistCm = labelled("bel|waist", waistRange)
        fit.hipCm = labelled("kalca|basen|hip|hips", hipRange)

        // Compact triplet "100/84/101" or "92-76-98": chest, waist, hip.
        if fit.chestCm == nil || fit.waistCm == nil || fit.hipCm == nil {
            for m in allMatches(#"(?<![\d.])(\d{2,3})\s*[/\-]\s*(\d{2,3})\s*[/\-]\s*(\d{2,3})(?![\d.])"#, in: w) {
                guard let c = Double(m[1]), let wa = Double(m[2]), let h = Double(m[3]) else { continue }
                let (cc, ww, hh) = inches && c < 60 ? (c * 2.54, wa * 2.54, h * 2.54) : (c, wa, h)
                if chestRange.contains(cc), waistRange.contains(ww), hipRange.contains(hh), ww < cc, ww < hh {
                    fit.chestCm = fit.chestCm ?? cc
                    fit.waistCm = fit.waistCm ?? ww
                    fit.hipCm = fit.hipCm ?? hh
                    break
                }
            }
        }

        fit.heightCm = height(in: w)
        fit.size = size(in: w)
        return fit
    }

    /// "1,90cm" (metres written with a cm suffix), "1.85 m", "1.85 boyunda", "188 cm",
    /// "boy: 188", "6'1"".
    static func height(in w: String) -> Double? {
        if let m = firstMatch(#"\b([4-7])\s*'\s*(\d{1,2})\s*("|''|in)?"#, in: w),
           let ft = Double(m[1]), let inch = Double(m[2]) {
            let cm = (ft * 12 + inch) * 2.54
            if heightRange.contains(cm) { return cm.rounded() }
        }
        if let m = firstMatch(#"(?<![\d.])([12]\.\d{2})\s*(m\b|cm\b|metre|boy|$|\s|-|,)"#, in: w), let v = Double(m[1]) {
            let cm = v * 100
            if heightRange.contains(cm) { return cm.rounded() }
        }
        if let m = firstMatch(#"\b(?:boy|boyu|height|tall)\b\s*[:=]?\s*(1\d{2})\b"#, in: w), let v = Double(m[1]), heightRange.contains(v) { return v }
        if let m = firstMatch(#"(?<![\d./])(1[4-9]\d|20\d)\s*cm\b"#, in: w), let v = Double(m[1]), heightRange.contains(v) { return v }
        return nil
    }

    static let sizeToken = #"(xxxs|xxs|xs|s|m|l|xl|xxl|xxxl|2xl|3xl|4xl|\d{2})"#

    /// "M beden", "beden: M", "bedeni M", "M bedendir", "wears a size M", "in size M", "size M".
    static func size(in w: String) -> String? {
        let patterns = [
            #"\b"# + sizeToken + #"\s*beden"#,
            #"\bbeden(?:i)?\s*[:=]?\s*"# + sizeToken + #"\b"#,
            #"\b(?:wears|wearing|in)\s+(?:a\s+)?(?:size\s+)?"# + sizeToken + #"\b"#,
            #"\bsize\s*[:=]?\s*"# + sizeToken + #"\b"#,
        ]
        for p in patterns {
            if let m = firstMatch(p, in: w) {
                let s = m[1].uppercased()
                // Two-digit sizes must look like clothing sizes, not a measurement.
                if let n = Int(s), !(24...60).contains(n) { continue }
                return s
            }
        }
        return nil
    }

    // MARK: - Text helpers

    /// Lowercased, diacritics folded (ö→o, ı→i), decimal commas as points, unified dashes.
    static func normalize(_ text: String) -> String {
        var s = SizeChartParser.fold(text)
        s = s.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        s = s.replacingOccurrences(of: "”", with: "\"").replacingOccurrences(of: "″", with: "\"").replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func matches(_ pattern: String, in s: String) -> [Range<String.Index>] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s) }
    }

    private static func allMatches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        }
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        allMatches(pattern, in: s).first
    }

    private static func slice(_ s: String, around r: Range<String.Index>, before: Int, after: Int) -> String {
        let start = s.index(r.lowerBound, offsetBy: -before, limitedBy: s.startIndex) ?? s.startIndex
        let end = s.index(r.upperBound, offsetBy: after, limitedBy: s.endIndex) ?? s.endIndex
        return String(s[start..<end])
    }
}
