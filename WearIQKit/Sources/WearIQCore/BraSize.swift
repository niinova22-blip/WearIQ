import Foundation

/// A bra size as people write it ("75B", "34 C", "80DD"): its band is the girth under the
/// breasts and its cup how far the bust stands out above it.
///
/// Bands from 60 up are European centimetres; up to 50, UK/US inches (a 34 band is
/// about 76–78 cm under the bust in today's sizing, so inches × 2.54 less a little).
/// Each cup is about 2 cm (EU) to 2.5 cm (UK/US) more than the one before, from AA.
public struct BraSize: Sendable, Equatable {
    public var underbustCm: Double
    /// Cup difference (bust minus underbust) the cup letter stands for, cm.
    public var cupCm: Double?

    public init?(_ text: String) {
        let t = text.uppercased().replacingOccurrences(of: " ", with: "")
        let digits = t.prefix { $0.isNumber }
        guard let band = Double(digits) else { return nil }
        let cup = String(t.dropFirst(digits.count))
        let inches = band <= 50
        if inches {
            guard (26...50).contains(band) else { return nil }
            underbustCm = band * 2.54 - 9
        } else {
            guard (55...130).contains(band) else { return nil }
            underbustCm = band
        }
        let letters = ["AA", "A", "B", "C", "D", "DD", "E", "F", "FF", "G", "GG", "H"]
        if cup.isEmpty {
            cupCm = nil
        } else if let index = letters.firstIndex(of: cup) {
            let step = inches ? 2.5 : 2.0
            cupCm = 11 + step * Double(index)
        } else {
            return nil
        }
    }
}
