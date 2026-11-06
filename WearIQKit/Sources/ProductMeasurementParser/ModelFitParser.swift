import Foundation
import WearIQCore

/// What a product page says about the model wearing the garment. Stores write this in
/// many ways, for example:
///
///     Modelin Ölçüleri M Beden - 1,90cm - 100/84/101
///     Manken Ölçüleri Boy: 188 cm Göğüs: 100 cm - Bel: 84 cm - Kalça: 96 cm. Mankenin üzerindeki ürün M bedendir.
///     Mankenimiz 1.85 boyunda, göğüs ölçüsü 95 cm, bel 75 cm, basen 95 cm. Üzerinde M beden var.
///     Model: 187 cm, 92-76-98, beden L
///     The model is 6'1" and wears a size M. Chest 38", waist 31"
///
/// Some pages show two models and what each wears on top and below (Mavi):
///
///     Manken Bilgileri
///     Boy: 179 cm, Göğüs: 85 cm, Bel: 60 cm, Kalça: 90 cm
///     Boy: 189 cm, Göğüs: 90 cm, Bel: 73 cm, Kalça: 92 cm
///     Kadın Manken: Jean: Bel: 26 / Boy: 30, Üst: S, Erkek Manken: Jean: Bel: 31 / Boy: 32, Üst: L
///
/// There the men's jeans being sold are the 31/32 on the man, not the "L" of the T-shirt
/// he wears with them, and his body is the second line, not the woman's first.
///
/// Convention in compact triplets ("100/84/101", "90-60-90"): chest/bust, waist, hip.
/// The size the model wears fits those body measurements, which anchors a size chart.
public struct ModelFit: Equatable, Sendable {
    /// The size worn: the one the page names, or the one for the garment once chosen.
    public var size: String?
    public var heightCm: Double?
    public var chestCm: Double?
    public var waistCm: Double?
    public var hipCm: Double?
    /// The size of the top the model wears ("Üst: L").
    public var topSize: String?
    /// The size of the trousers, jeans or skirt the model wears ("Jean: 31/32").
    public var bottomSize: String?
    /// Whose measurements these are, when the page has a men's and a women's model.
    public var audience: GarmentAudience?

    public init(size: String? = nil, heightCm: Double? = nil, chestCm: Double? = nil, waistCm: Double? = nil,
                hipCm: Double? = nil, topSize: String? = nil, bottomSize: String? = nil, audience: GarmentAudience? = nil) {
        self.size = size
        self.heightCm = heightCm
        self.chestCm = chestCm
        self.waistCm = waistCm
        self.hipCm = hipCm
        self.topSize = topSize
        self.bottomSize = bottomSize
        self.audience = audience
    }

    /// Usable as a chart anchor: the worn size plus at least one girth.
    public var isAnchor: Bool { size != nil && girthCount > 0 }

    /// The size the model wears of this kind of garment: the trousers' size for trousers
    /// (never the T-shirt worn with them), the top's for a top.
    public func wornSize(for category: GarmentCategory?) -> String? {
        guard let category else { return size ?? topSize ?? bottomSize }
        if category.isBottom { return bottomSize ?? (topSize == nil ? size : nil) }
        if category == .dress { return size ?? topSize }
        return topSize ?? (bottomSize == nil ? size : nil)
    }

    var girthCount: Int { [chestCm, waistCm, hipCm].compactMap { $0 }.count }

    fileprivate var fieldCount: Int {
        [size != nil || topSize != nil || bottomSize != nil, heightCm != nil, chestCm != nil, waistCm != nil, hipCm != nil]
            .filter { $0 }.count
    }
}

public enum ModelFitParser {
    static let chestRange: ClosedRange<Double> = 70...140
    static let waistRange: ClosedRange<Double> = 50...130
    static let hipRange: ClosedRange<Double> = 70...145
    static let heightRange: ClosedRange<Double> = 140...210

    /// The model's fit. With a men's and a women's model on the page, the one for
    /// `audience` (none when it isn't known: either body would anchor the chart wrongly
    /// half the time). `size` becomes the size worn of `category`'s kind: the jeans' size
    /// for jeans, the top's for a top.
    public static func parse(_ text: String, audience: GarmentAudience? = nil, category: GarmentCategory? = nil) -> ModelFit? {
        let candidates = parseAll(text)
        guard !candidates.isEmpty else { return nil }
        var pool = candidates
        let named = Set(candidates.compactMap(\.audience))
        if let audience, named.contains(audience) {
            pool = candidates.filter { $0.audience == audience }
        } else if named.count > 1 {
            pool = candidates.filter { $0.audience == nil }
        }
        guard var best = pool.max(by: { $0.fieldCount < $1.fieldCount }) else { return nil }
        best.size = best.wornSize(for: category)
        return best
    }

    /// Every model the text describes: one per men's or women's model when the page names
    /// them, otherwise the best-described mention of a model.
    public static func parseAll(_ text: String) -> [ModelFit] {
        let t = normalize(text)
        let markers = genderMarkers(in: t)
        if !markers.isEmpty {
            let named = namedModels(t, markers: markers)
            if named.contains(where: { $0.fieldCount > 0 }) { return named }
        }
        // Only look near a mention of the model, so the store's general size advice
        // ("chest 95 cm fits M") isn't taken for the model's measurements.
        var best: ModelFit?
        for anchor in matches(#"\b(manken\w*|model\w*|the model)\b"#, in: t) {
            let window = slice(t, around: anchor, before: 60, after: 260)
            let fit = parseWindow(window)
            if fit.fieldCount > (best?.fieldCount ?? 0) { best = fit }
        }
        return best.map { [$0] } ?? []
    }

    // MARK: - Several models

    private struct Marker {
        var range: Range<String.Index>
        var audience: GarmentAudience
    }

    /// "Kadın manken", "erkek model", "female model", "men's model", "model (kadın)".
    private static func genderMarkers(in t: String) -> [Marker] {
        let words: [(String, GarmentAudience)] = [(#"kadin|bayan|women'?s|woman|female|ladies"#, .women),
                                                  (#"erkek|men'?s|man|male"#, .men)]
        var result: [Marker] = []
        for (w, audience) in words {
            let patterns = [#"\b(?:"# + w + #")\s+(?:manken\w*|model\w*)\b"#,
                            #"\b(?:manken\w*|model\w*)\s*\(\s*(?:"# + w + #")\s*\)"#]
            for p in patterns {
                for r in matches(p, in: t) where !result.contains(where: { $0.range.overlaps(r) }) {
                    result.append(Marker(range: r, audience: audience))
                }
            }
        }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Each named model's part of the text, from its name to the next. A part with no
    /// body measurements of its own takes the body line in the same place in the block
    /// above the names: Mavi lists the bodies first, then "Kadın Manken: …, Erkek Manken: …".
    private static func namedModels(_ t: String, markers: [Marker]) -> [ModelFit] {
        guard let first = markers.first else { return [] }
        let blockStart = t.index(first.range.lowerBound, offsetBy: -320, limitedBy: t.startIndex) ?? t.startIndex
        var head = String(t[blockStart..<first.range.lowerBound])
        // The bodies belong to the models' block: start at its last heading ("manken
        // bilgileri") when there is one, so an earlier unrelated size line stays out.
        if let heading = matches(#"\b(manken\w*|model\w*)\b"#, in: head).last {
            head = String(head[heading.lowerBound...])
        }
        let bodies = measurementSets(head)
        var fits: [ModelFit] = []
        for (i, marker) in markers.enumerated() {
            let end = i + 1 < markers.count ? markers[i + 1].range.lowerBound
                : (t.index(marker.range.upperBound, offsetBy: 200, limitedBy: t.endIndex) ?? t.endIndex)
            var fit = parseWindow(String(t[marker.range.lowerBound..<end]))
            fit.audience = marker.audience
            if fit.girthCount == 0, bodies.count == markers.count {
                let body = bodies[i]
                fit.heightCm = fit.heightCm ?? body.heightCm
                fit.chestCm = body.chestCm
                fit.waistCm = body.waistCm
                fit.hipCm = body.hipCm
            }
            fits.append(fit)
        }
        return fits
    }

    /// Body lines one after another ("Boy: 179, Göğüs: 85 … Boy: 189, Göğüs: 90 …"): a
    /// measurement seen a second time starts the next body.
    static func measurementSets(_ s: String) -> [ModelFit] {
        enum Kind: Hashable { case height, chest, waist, hip }
        var tokens: [(pos: String.Index, kind: Kind, value: Double)] = []
        func add(_ pattern: String, _ kind: Kind, _ range: ClosedRange<Double>, scale: Double = 1) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range(at: 1), in: s), let whole = Range(m.range, in: s),
                      let raw = Double(s[r]) else { continue }
                let v = raw * scale
                guard range.contains(v) else { continue }
                tokens.append((whole.lowerBound, kind, v))
            }
        }
        let says = #"(?:\s*(?:olcusu|cevresi))?\s*[:=]?\s*"#
        add(#"\b(?:boy|boyu|height)\b\s*[:=]?\s*(1\d{2}|20\d)\b"#, .height, heightRange)
        add(#"\b(?:boy|boyu|height)\b\s*[:=]?\s*([12]\.\d{2})\b"#, .height, heightRange, scale: 100)
        add(#"\b(?:gogus|chest|bust)\b"# + says + #"(\d{2,3}(?:\.\d)?)"#, .chest, chestRange)
        add(#"\b(?:bel|waist)\b"# + says + #"(\d{2,3}(?:\.\d)?)"#, .waist, waistRange)
        add(#"\b(?:kalca|basen|hips?)\b"# + says + #"(\d{2,3}(?:\.\d)?)"#, .hip, hipRange)
        tokens.sort { $0.pos < $1.pos }
        var sets: [ModelFit] = []
        var current = ModelFit()
        var seen: Set<Kind> = []
        for token in tokens {
            if seen.contains(token.kind) {
                sets.append(current)
                current = ModelFit()
                seen = []
            }
            seen.insert(token.kind)
            switch token.kind {
            case .height: current.heightCm = token.value
            case .chest: current.chestCm = token.value
            case .waist: current.waistCm = token.value
            case .hip: current.hipCm = token.value
            }
        }
        if !seen.isEmpty { sets.append(current) }
        return sets.filter { $0.girthCount > 0 }
    }

    // MARK: - Window parsing

    static func parseWindow(_ w: String) -> ModelFit {
        var fit = ModelFit()
        let inches = w.contains("\"") || w.contains(" inch") || w.contains(" in.")

        // Labelled girths: "göğüs: 100", "gogus olcusu 95 cm", "bust 34\"", "kalça/basen".
        func labelled(_ labels: String, _ range: ClosedRange<Double>) -> Double? {
            for m in allMatches(#"\b(?:"# + labels + #")\b(?:\s*(?:olcusu|cevresi|ölçüsü))?\s*[:=]?\s*(\d{2,3}(?:\.\d)?)\s*(cm|"|inch)?"#, in: w) {
                guard var v = Double(m[1]) else { continue }
                if m[2] == "\"" || m[2] == "inch" || (m[2].isEmpty && inches && v < 60) { v *= 2.54 }
                // "Jean: Bel: 31" is the jeans' waist size, not the model's waist: skip
                // values out of a body's range and keep looking.
                if range.contains(v) { return v }
            }
            return nil
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
        fit.bottomSize = bottomSize(in: w)
        fit.topSize = topSize(in: w)
        if fit.bottomSize == nil, fit.topSize == nil { fit.size = size(in: w) }
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

    /// Longest first, so "xl" isn't read as "x" + "l".
    static let sizeToken = #"(xxxs|xxs|xs|xxxl|xxl|xl|2xl|3xl|4xl|5xl|s|m|l|\d{2})"#

    /// "M beden", "beden: M", "bedeni M", "M bedendir", "wears a size M", "in size M", "size M".
    static func size(in w: String) -> String? {
        let patterns = [
            #"\b"# + sizeToken + #"\s*beden"#,
            #"\bbeden(?:i)?\s*[:=]?\s*"# + sizeToken + #"\b"#,
            #"\b(?:wears|wearing|in)\s+(?:a\s+)?(?:size\s+)?"# + sizeToken + #"\b"#,
            #"\bsize\s*[:=]?\s*"# + sizeToken + #"\b"#,
        ]
        for p in patterns {
            for m in allMatches(p, in: w) {
                if let s = clean(m[1]) { return s }
            }
        }
        return nil
    }

    /// The size of the trousers or skirt worn: "Jean: Bel: 31 / Boy: 32" → "31/32",
    /// "pantolon 32x34", "jeans W30 L32", "etek: 38", "alt: M".
    static func bottomSize(in w: String) -> String? {
        let part = #"\b(?:jean|jeans|denim|kot|pantolon|alt|etek|sort|trousers?|pants|bottoms?|skirt|shorts)\b\s*[:=]?\s*(?:beden\s*[:=]?\s*)?"#
        let waistLength = #"(?:(?:bel|waist|w)\s*[:=]?\s*)?(\d{2})\s*(?:[/x\-]\s*(?:(?:boy|length|l)\s*[:=]?\s*)?|(?:boy|length|l)\s*[:=]?\s*)(\d{2})\b"#
        for pattern in [part + waistLength, #"\bw\s*(\d{2})\s*[/x]?\s*l\s*(\d{2})\b"#] {
            if let m = firstMatch(pattern, in: w), let waist = Int(m[1]), let length = Int(m[2]),
               (22...52).contains(waist), (26...38).contains(length) {
                return "\(waist)/\(length)"
            }
        }
        if let m = firstMatch(part + #"(?:(?:bel|waist|w)\s*[:=]?\s*)?"# + sizeToken + #"\b"#, in: w) {
            return clean(m[1])
        }
        return nil
    }

    /// The size of the top worn: "Üst: L", "gömlek M", "top: S".
    static func topSize(in w: String) -> String? {
        let part = #"\b(?:ust|top|tops|upper|gomlek|tisort|t-shirt|tshirt|shirt|ceket|jacket|kazak|sweatshirt|bluz|blouse)\b\s*[:=]?\s*(?:beden\s*[:=]?\s*)?"#
        guard let m = firstMatch(part + sizeToken + #"\b"#, in: w) else { return nil }
        return clean(m[1])
    }

    /// Two-digit sizes must look like clothing sizes, not a measurement.
    private static func clean(_ token: String) -> String? {
        let s = token.uppercased()
        if let n = Int(s), !(24...60).contains(n) { return nil }
        return s
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
