import Foundation

/// What a product page says about the model wearing the garment, e.g.
/// "Manken ölçüleri: Boy 188 cm, Göğüs: 100 cm - Bel: 84 cm. Mankenin üzerindeki ürün M bedendir."
/// The size the model wears fits those body measurements, which anchors a size chart
/// when the store publishes none.
public struct ModelFit: Equatable, Sendable {
    public var size: String?
    public var heightCm: Double?
    public var chestCm: Double?
    public var waistCm: Double?
    public var hipCm: Double?

    /// Usable as a chart anchor: the worn size plus at least one girth.
    public var isAnchor: Bool { size != nil && (chestCm != nil || waistCm != nil || hipCm != nil) }
}

public enum ModelFitParser {
    public static func parse(_ text: String) -> ModelFit? {
        let folded = SizeChartParser.fold(text)
        // Only look near a mention of the model, so the store's general size advice
        // ("chest 95 cm fits M") isn't mistaken for the model's measurements.
        guard let anchor = folded.range(of: #"\b(manken|model)"#, options: .regularExpression) else { return nil }
        let start = folded.index(anchor.lowerBound, offsetBy: -150, limitedBy: folded.startIndex) ?? folded.startIndex
        let end = folded.index(anchor.upperBound, offsetBy: 300, limitedBy: folded.endIndex) ?? folded.endIndex
        let window = String(folded[start..<end])

        func number(_ pattern: String, _ range: ClosedRange<Double>) -> Double? {
            guard let r = window.range(of: pattern, options: .regularExpression) else { return nil }
            let digits = window[r].components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted).filter { !$0.isEmpty }
            return digits.last.flatMap(Double.init).flatMap { range.contains($0) ? $0 : nil }
        }

        var fit = ModelFit()
        fit.chestCm = number(#"\b(gogus|chest|bust)\b\s*(olcusu)?\s*[:=]?\s*\d{2,3}"#, 70...140)
        fit.waistCm = number(#"\b(bel|waist)\b\s*(olcusu)?\s*[:=]?\s*\d{2,3}"#, 50...130)
        fit.hipCm = number(#"\b(kalca|basen|hip|hips)\b\s*(olcusu)?\s*[:=]?\s*\d{2,3}"#, 70...140)
        fit.heightCm = number(#"\b(boy|boyu|height)\b\s*[:=]?\s*1\d{2}"#, 140...210)

        let sizes = #"(xxs|xs|s|m|l|xl|xxl|2xl|3xl|\d{2})"#
        let sizePatterns = [
            #"\b"# + sizes + #"\s*beden(dir|i)?\s*(giy|kullan|tercih)?"#,  // "M beden giymektedir", "M bedendir"
            #"bedeni?\s*[:=]?\s*"# + sizes + #"\b"#,                       // "modelin bedeni: 36"
            #"(wears|wearing)\s*(a\s*)?(size\s*)?"# + sizes + #"\b"#,      // "model wears size M"
            #"size\s*"# + sizes + #"\b"#,
        ]
        for pattern in sizePatterns {
            guard let r = window.range(of: pattern, options: .regularExpression) else { continue }
            let match = String(window[r])
            if let s = match.range(of: #"\b"# + sizes + #"\b"#, options: .regularExpression) {
                fit.size = String(match[s]).uppercased()
                break
            }
        }
        return fit == ModelFit() ? nil : fit
    }
}
