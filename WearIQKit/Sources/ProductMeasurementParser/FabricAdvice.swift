import Foundation
import WearIQCore

/// What the fabric composition means for wear and care, from textile basics:
/// elastane (spandex, Lycra) is what makes a woven or knit garment stretch and recover;
/// cotton, viscose and wool shrink when washed warm or tumble-dried (cotton typically
/// 3–5%); linen wrinkles readily and softens with wear; polyester and polyamide hold
/// their shape and don't shrink but breathe less; rigid all-cotton denim gives a little
/// at the waist as it's worn.
public enum FabricAdvice {
    public enum Fibre: String, CaseIterable, Sendable {
        case elastane, cotton, polyester, viscose, wool, linen, polyamide, acrylic
    }

    public enum Note: Equatable, Sendable {
        /// 1–3% elastane: gives with movement, keeps its shape.
        case someStretch(percent: Double)
        /// 4% or more elastane: stretches clearly; a snug size stays comfortable.
        case highStretch(percent: Double)
        /// No elastane in a woven: doesn't give; if it's tight it stays tight.
        case noStretch
        /// Mostly cotton: may shrink a few per cent in a warm wash or the dryer.
        case cottonShrinks
        case viscoseShrinks
        case woolShrinks
        case linenWrinkles
        /// Mostly synthetic: keeps its shape, doesn't shrink, breathes less.
        case syntheticStable
        /// Rigid all-cotton denim loosens a little at the waist as it's worn.
        case denimGives
    }

    /// Fibre percentages from "%98 Pamuk %2 Elastan", "98% cotton, 2% elastane" or
    /// "Pamuk: %95, Elastan: %5".
    public static func fibres(in text: String) -> [Fibre: Double] {
        let t = SizeChartParser.fold(text)
        let names: [(Fibre, String)] = [
            (.elastane, "elastan\\w*|spandex|lycra|likra"), (.cotton, "pamuk|cotton|koton"),
            (.polyester, "polyester|poliester"), (.viscose, "viskon|viscose|rayon|modal|lyocell|tencel"),
            (.wool, "yun|wool|merino|kasmir|cashmere"), (.linen, "keten|linen"),
            (.polyamide, "poliamid|polyamid\\w*|nylon|naylon"), (.acrylic, "akrilik|acrylic"),
        ]
        var result: [Fibre: Double] = [:]
        for (fibre, pattern) in names {
            let forms = [
                #"%\s*(\d{1,3}(?:[.,]\d+)?)\s*(?:"# + pattern + ")",
                #"(\d{1,3}(?:[.,]\d+)?)\s*%\s*(?:"# + pattern + ")",
                "(?:" + pattern + #")\s*[:\-]?\s*%?\s*(\d{1,3}(?:[.,]\d+)?)\s*%?"#,
            ]
            for form in forms {
                guard let regex = try? NSRegularExpression(pattern: form),
                      let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                      let r = Range(m.range(at: 1), in: t),
                      let value = Double(t[r].replacingOccurrences(of: ",", with: ".")), value > 0, value <= 100 else { continue }
                result[fibre] = max(result[fibre] ?? 0, value)
                break
            }
        }
        // A list that adds up far past 100% was misread.
        return result.values.reduce(0, +) <= 101 ? result : [:]
    }

    public static func notes(composition: String, category: GarmentCategory?, productName: String? = nil) -> [Note] {
        let f = fibres(in: composition)
        guard !f.isEmpty else { return [] }
        var notes: [Note] = []
        let elastane = f[.elastane] ?? 0
        if elastane >= 4 { notes.append(.highStretch(percent: elastane)) }
        else if elastane > 0 { notes.append(.someStretch(percent: elastane)) }
        else if (f[.wool] ?? 0) < 50 { notes.append(.noStretch) }
        if (f[.cotton] ?? 0) >= 80, elastane < 3 { notes.append(.cottonShrinks) }
        if (f[.viscose] ?? 0) >= 30 { notes.append(.viscoseShrinks) }
        if (f[.wool] ?? 0) >= 30 { notes.append(.woolShrinks) }
        if (f[.linen] ?? 0) >= 30 { notes.append(.linenWrinkles) }
        if (f[.polyester] ?? 0) + (f[.polyamide] ?? 0) + (f[.acrylic] ?? 0) >= 60 { notes.append(.syntheticStable) }
        let name = SizeChartParser.fold(productName ?? "")
        if category == .pants, (f[.cotton] ?? 0) >= 98, name.contains("jean") || name.contains("denim") || name.contains("kot") {
            notes.append(.denimGives)
        }
        return notes
    }

    /// Fabric that may shrink makes a size that's already close-fitting riskier.
    public static func shrinkRisk(_ notes: [Note]) -> Bool {
        notes.contains { [.cottonShrinks, .viscoseShrinks, .woolShrinks].contains($0) }
    }

    /// The composition sentence on a product page ("Kumaş: %98 Pamuk %2 Elastan").
    public static func compositionText(in text: String) -> String? {
        let pattern = #"(?:%\s*\d{1,3}\s*[A-Za-zÇĞİÖŞÜçğıöşü]+[\s,/]*){1,5}|(?:\d{1,3}\s*%\s*[A-Za-zÇĞİÖŞÜçğıöşü]+[\s,/]*){1,5}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m -> String? in
            Range(m.range, in: text).map { String(text[$0]) }
        }
        return matches.first { !fibres(in: $0).isEmpty }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
