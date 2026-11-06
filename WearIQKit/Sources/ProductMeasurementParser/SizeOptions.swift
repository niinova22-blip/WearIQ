import Foundation
import WearIQCore

/// A size selector as the page shows it: its caption ("Beden", "Bel", "Boy", "Length")
/// and its options in order.
public struct SizeOptionGroup: Codable, Sendable, Equatable {
    public var caption: String
    public var labels: [String]

    public init(caption: String, labels: [String]) {
        self.caption = caption
        self.labels = labels
    }
}

/// Picks the product's sizes from the size selectors visible on a product page.
///
/// A page shows more than the product's own sizes: a hidden "Beden Seç" sheet for a
/// recommended T-shirt (Mavi's Insider widget lists XS S M L next to a pair of jeans),
/// carousels, a quantity picker (1 2 3 4 5). The browser side (`script`) keeps only
/// visible selectors outside such widgets; this side keeps groups that look like a size
/// range, and joins a waist selector and a length selector into W/L sizes ("31/32"),
/// which is what such stores sell.
public enum SizeOptions {
    /// Gathers the visible size selectors, in page order, as `[{caption, labels}]`.
    /// Shared by the app's page reader and the Safari extension (keep them alike).
    public static let script = #"""
    (() => {
      const SIZE = /^(XXXS|XXS|XS|S|M|L|XL|XXL|XXXL|[2-6]XL|W?\d{2}(\s?[\/xX]\s?L?\d{2})?|W\d{2}\s?L\d{2}|\d{1,2}|\d{2}[A-H]{1,2})$/i;
      const SKIP = /(^|[\s_-])(recommend\w*|recommendation\w*|reco|similar|related|carousel|slider|swiper|slick|upsell|cross-?sell|stylitics|insider|ins|benzer|oneri|kombin\w*|footer|filters?|facets?|qty|quantity|adet|miktar|pagination|rating\w*)([\s_-]|$)/i;
      const visible = (e) => {
        if (!e) return false;
        const s = getComputedStyle(e);
        if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') return false;
        const r = e.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
      };
      const excluded = (e) => {
        for (let p = e; p && p !== document.body; p = p.parentElement) {
          if (p.getAttribute('aria-hidden') === 'true' || p.hidden) return true;
          const c = ((p.className && p.className.toString()) || '') + ' ' + (p.id || '') + ' ' + (p.getAttribute('name') || '');
          if (SKIP.test(c)) return true;
        }
        return false;
      };
      const boxes = [], byBox = new Map();
      for (const e of document.querySelectorAll('button, li, label, option, a[role="button"], [role="radio"], [role="option"], span[class*="size" i], div[class*="size" i]')) {
        const s = (e.innerText || e.textContent || '').trim().replace(/\s+/g, ' ');
        if (!s || s.length > 9 || !SIZE.test(s)) continue;
        if (!visible(e.tagName === 'OPTION' ? e.parentElement : e) || excluded(e)) continue;
        let box = e.parentElement;
        while (box && box.children.length === 1 && box.parentElement && box !== document.body) box = box.parentElement;
        if (!byBox.has(box)) { byBox.set(box, []); boxes.push(box); }
        const list = byBox.get(box);
        if (!list.includes(s)) list.push(s);
      }
      const caption = (box) => {
        const own = box.getAttribute('aria-label') || box.getAttribute('data-label') || '';
        if (own) return own;
        if (box.id) { const l = document.querySelector('label[for="' + box.id + '"]'); if (l) return l.innerText; }
        for (let p = box, i = 0; p && i < 3; p = p.parentElement, i++) {
          const prev = p.previousElementSibling;
          if (prev && prev.innerText && prev.innerText.trim().length < 40) return prev.innerText;
        }
        return '';
      };
      return boxes.slice(0, 10).map(b => ({ caption: caption(b).trim().replace(/\s+/g, ' ').slice(0, 40), labels: byBox.get(b).slice(0, 60) }));
    })()
    """#

    /// The product's sizes from the visible selectors, or none when no group is a size range.
    public static func labels(from groups: [SizeOptionGroup], category: GarmentCategory?) -> [String] {
        let groups = groups.map { g in
            SizeOptionGroup(caption: SizeChartParser.fold(g.caption),
                            labels: g.labels.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty })
        }.filter { !$0.labels.isEmpty && !isQuantity($0) }
        let bottom = category?.isBottom ?? false
        // Waist and length picked separately: "Bel 28 29 30 …" and "Boy 30 32 34".
        if bottom {
            let lengths = groups.first { g in
                caption(g, ["boy", "length", "inseam", "uzunluk", "paca", "leg", "l"]) && numbers(g).map { $0.allSatisfy((26...38).contains) } == true
            }
            let waists = groups.first { g in
                g != lengths && caption(g, ["bel", "waist", "beden", "size", "w"]) && numbers(g).map { $0.allSatisfy((22...52).contains) } == true
            }
            if let lengths, let waists {
                return waists.labels.flatMap { w in lengths.labels.map { "\(w.filter(\.isNumber))/\($0.filter(\.isNumber))" } }
            }
        }
        // Otherwise the first selector that is a size range (the product's own comes
        // before anything further down the page).
        for g in groups where g.labels.count >= 2 && looksLikeSizes(g.labels, bottom: bottom) {
            if bottom, caption(g, ["boy", "length", "uzunluk"]) { continue }
            return g.labels
        }
        if groups.count == 1, let only = groups.first, looksLikeSizes(only.labels, bottom: bottom) { return only.labels }
        return []
    }

    private static func caption(_ g: SizeOptionGroup, _ words: [String]) -> Bool {
        let t = " " + g.caption.replacingOccurrences(of: #"[^a-z0-9]"#, with: " ", options: .regularExpression) + " "
        return words.contains { t.contains(" \($0) ") || ($0.count > 2 && t.contains(" \($0)")) }
    }

    private static func numbers(_ g: SizeOptionGroup) -> [Int]? {
        let n = g.labels.compactMap { Int($0.filter(\.isNumber)) }
        return n.count == g.labels.count && g.labels.allSatisfy({ $0.count <= 3 }) ? n : nil
    }

    private static func isQuantity(_ g: SizeOptionGroup) -> Bool {
        if ["adet", "qty", "quantity", "miktar", "sayfa", "page"].contains(where: g.caption.contains) { return true }
        // 1 2 3 4 5: a quantity or a page list, not sizes.
        if let n = Int(g.labels.first ?? ""), n <= 1, g.labels.count >= 3,
           g.labels.compactMap(Int.init) == Array(n..<(n + g.labels.count)) { return true }
        return false
    }

    /// Letters, waist/length pairs, or numbers of one size system.
    static func looksLikeSizes(_ labels: [String], bottom: Bool) -> Bool {
        let letters = Set(SizeOrder.letters)
        if labels.allSatisfy({ letters.contains($0) || $0 == "XXXL" || $0.hasSuffix("XL") }) { return true }
        if labels.allSatisfy({ SizeLabel.waistLength($0) != nil }) { return bottom || labels.count > 1 }
        let n = labels.compactMap { Int($0.hasPrefix("W") ? String($0.dropFirst()) : $0) }
        if n.count == labels.count {
            // One system: all two-digit (waists, EU sizes), or US women's 0–24 in even steps.
            return n.allSatisfy({ (22...64).contains($0) }) || n.allSatisfy({ (0...24).contains($0) && $0 % 2 == 0 })
        }
        // Bra sizes (75B) and the like.
        return labels.allSatisfy { $0.range(of: #"^\d{2}[A-H]{1,2}$"#, options: .regularExpression) != nil }
    }
}
