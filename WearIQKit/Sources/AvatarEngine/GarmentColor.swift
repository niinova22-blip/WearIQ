import Foundation

/// The garment's main colour from pixels of the product photo where it is worn (the
/// torso of the model for a top, the legs for trousers), so the avatar can wear it in
/// its own colour as well as in the fit colours.
///
/// A few clusters (k-means in a perceptual-ish space): the biggest wins, unless it looks
/// like skin and another cluster is large too (a neckline or bare arms in the sample).
/// Prints and stripes show as several large clusters; `patterned` says so, and the app
/// then names the colour as the main one of a pattern.
public enum GarmentColor {
    public struct RGB: Sendable, Equatable {
        public var r: Double, g: Double, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    }

    public struct Result: Sendable, Equatable {
        /// 0–1 components.
        public var color: RGB
        /// Share of the sample in the chosen cluster.
        public var share: Double
        /// No single colour covers most of the garment.
        public var patterned: Bool
    }

    /// Needs at least 50 pixels (0–1 components).
    public static func dominant(_ pixels: [RGB], clusters k: Int = 4) -> Result? {
        guard pixels.count >= 50 else { return nil }
        // Deterministic sample for speed.
        let step = max(1, pixels.count / 4000)
        let sample = stride(from: 0, to: pixels.count, by: step).map { pixels[$0] }
        // Initial centres spread over brightness.
        let sorted = sample.sorted { luma($0) < luma($1) }
        var centres: [RGB] = []
        for c in 0..<k {
            let index: Int = (2 * c + 1) * sorted.count / (2 * k)
            centres.append(sorted[min(sorted.count - 1, index)])
        }
        var assignment = [Int](repeating: 0, count: sample.count)
        for _ in 0..<12 {
            for (i, p) in sample.enumerated() {
                assignment[i] = centres.indices.min { distance(p, centres[$0]) < distance(p, centres[$1]) }!
            }
            for c in centres.indices {
                var r = 0.0, g = 0.0, b = 0.0, n = 0.0
                for (i, p) in sample.enumerated() where assignment[i] == c {
                    r += p.r; g += p.g; b += p.b; n += 1
                }
                guard n > 0 else { continue }
                centres[c] = RGB(r / n, g / n, b / n)
            }
        }
        let counts = centres.indices.map { c in assignment.filter { $0 == c }.count }
        let order = centres.indices.sorted { counts[$0] > counts[$1] }
        let total = Double(sample.count)
        var pick = order[0]
        if looksLikeSkin(centres[pick]), order.count > 1, Double(counts[order[1]]) / total >= 0.2 {
            pick = order[1]
        }
        let share = Double(counts[pick]) / total
        // Merge near-identical clusters (shading of one colour) before calling it a print.
        let similar = centres.indices.filter { distance(centres[$0], centres[pick]) < 0.03 }
        let mainShare = Double(similar.reduce(0) { $0 + counts[$1] }) / total
        return Result(color: centres[pick], share: share, patterned: mainShare < 0.55)
    }

    static func luma(_ p: RGB) -> Double {
        let r: Double = 0.299 * p.r, g: Double = 0.587 * p.g, b: Double = 0.114 * p.b
        return r + g + b
    }

    /// Squared distance weighted towards how the eye separates colours.
    static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr: Double = a.r - b.r, dg: Double = a.g - b.g, db: Double = a.b - b.b
        let rMean: Double = (a.r + b.r) / 2
        let red: Double = (2 + rMean) * dr * dr
        let green: Double = 4 * dg * dg
        let blue: Double = (3 - rMean) * db * db
        return red + green + blue
    }

    /// Typical skin in YCbCr (Chai & Ngan), over all skin tones.
    static func looksLikeSkin(_ p: RGB) -> Bool {
        let y: Double = luma(p)
        let cbUnit: Double = -0.168736 * p.r - 0.331264 * p.g + 0.5 * p.b
        let crUnit: Double = 0.5 * p.r - 0.418688 * p.g - 0.081312 * p.b
        let cb: Double = 128 + 255 * cbUnit
        let cr: Double = 128 + 255 * crUnit
        return y > 0.15 && (77...127).contains(cb) && (133...173).contains(cr)
    }
}
