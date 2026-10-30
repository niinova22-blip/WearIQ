import Foundation

/// How a fabric behaves on the body, from its composition.
///
/// Stretch: elastane is what lets a fabric extend and recover; knits give more than
/// wovens. A rigid woven takes about 3–4% before it pulls, a plain knit around 12%, and
/// each per cent of elastane adds roughly 4% (a 98/2 stretch chino ≈ 11%, a 95/5 jersey
/// ≈ 32%).
///
/// Drape: the Cusick drape coefficient, the share of a draped disc's shadow against its
/// flat area. Fluid fabrics (viscose, silk) sit around 0.2–0.4 and fall into many deep
/// folds; cotton around 0.5–0.6; linen and denim 0.7 and above hang stiffly in a few
/// wide folds. The number of folds a drape forms falls as the coefficient rises.
public struct Fabric: Equatable, Sendable {
    /// Extension taken comfortably before the fabric pulls, as a fraction.
    public var stretchLimit: Float
    /// Cusick drape coefficient, 0 (fluid) to 1 (stiff).
    public var drape: Float
    /// Weight per area, g/m². Heavier fabric hangs straighter and presses harder.
    public var density: Float
    /// Thickness, metres: how far the fabric's midline sits off the skin.
    public var thickness: Float
    /// Friction against skin: how much fabric resting on the body resists sliding.
    public var friction: Float

    public init(stretchLimit: Float, drape: Float, density: Float = 160, thickness: Float = 0.0005,
                friction: Float = 0.45) {
        self.stretchLimit = max(0.02, stretchLimit)
        self.drape = min(0.95, max(0.15, drape))
        self.density = min(600, max(40, density))
        self.thickness = min(0.003, max(0.0002, thickness))
        self.friction = min(0.9, max(0.1, friction))
    }

    public static let woven = Fabric(stretchLimit: 0.035, drape: 0.6, density: 130, thickness: 0.0003)
    public static let knit = Fabric(stretchLimit: 0.12, drape: 0.45, density: 160, thickness: 0.0006)

    /// Typical fabrics of each kind, from the composition rules below: a cotton jersey
    /// T-shirt, a cotton poplin shirt, 12 oz denim, a linen shirt, a wool suiting, a
    /// polyester shirt and a 95/5 cotton–elastane jersey.
    public static let cottonJersey = Fabric(fibres: ["cotton": 100], knit: true)
    public static let cottonShirting = Fabric(fibres: ["cotton": 100], knit: false)
    public static let denim = Fabric(fibres: ["cotton": 100], knit: false, weight: 400)
    public static let linen = Fabric(fibres: ["linen": 100], knit: false)
    public static let wool = Fabric(fibres: ["wool": 100], knit: false)
    public static let polyester = Fabric(fibres: ["polyester": 100], knit: false)
    public static let stretchJersey = Fabric(fibres: ["cotton": 95, "elastane": 5], knit: true)

    /// From fibre percentages keyed by fibre name (elastane, cotton, polyester, viscose,
    /// wool, linen, polyamide, acrylic); unknown or missing fibres count as cotton.
    ///
    /// Per fibre, typical values for apparel fabrics made of it: the drape coefficient as
    /// above; friction against skin (cotton and linen grip more than smooth synthetics
    /// and viscose); relative thickness and weight. Weight when the page doesn't give it
    /// (`weight`, g/m²): a plain single jersey about 160, a shirting about 120, scaled by
    /// the fibre (linen and wool cloth run heavier, polyester and viscose lighter). These
    /// describe a kind of fabric, not this garment's: an unknown fabric is estimated.
    public init(fibres: [String: Double], knit: Bool, weight: Float? = nil) {
        struct Fibre { let drape, friction, thickness, weight: Float }
        let table: [String: Fibre] = [
            "cotton": Fibre(drape: 0.55, friction: 0.5, thickness: 1, weight: 1),
            "viscose": Fibre(drape: 0.28, friction: 0.35, thickness: 0.8, weight: 0.9),
            "wool": Fibre(drape: 0.5, friction: 0.5, thickness: 1.6, weight: 1.6),
            "linen": Fibre(drape: 0.72, friction: 0.55, thickness: 1.2, weight: 1.3),
            "polyester": Fibre(drape: 0.45, friction: 0.3, thickness: 0.8, weight: 0.85),
            "polyamide": Fibre(drape: 0.4, friction: 0.3, thickness: 0.7, weight: 0.8),
            "acrylic": Fibre(drape: 0.55, friction: 0.4, thickness: 1.4, weight: 1.1),
            "elastane": Fibre(drape: 0.5, friction: 0.5, thickness: 1, weight: 1),
        ]
        let total = fibres.values.reduce(0, +)
        let mix = total > 0 ? fibres : ["cotton": 100]
        let sum = Float(total > 0 ? total : 100)
        var drape: Float = 0, friction: Float = 0, thick: Float = 0, heavy: Float = 0
        for (fibre, percent) in mix {
            let f = table[fibre] ?? table["cotton"]!
            let share = Float(percent) / sum
            drape += f.drape * share
            friction += f.friction * share
            thick += f.thickness * share
            heavy += f.weight * share
        }
        let elastane = Float(fibres["elastane"] ?? 0)
        let base: Float = knit ? 160 : 120
        let grams = weight ?? base * heavy
        // Heavier wovens drape stiffer (denim): a little per 100 g/m² over a shirting.
        let stiffening: Float = knit ? 0 : max(0, grams - 150) / 100 * 0.05
        self.init(stretchLimit: (knit ? 0.12 : 0.035) + 0.04 * min(elastane, 10),
                  drape: drape - (knit ? 0.08 : 0) + stiffening,
                  density: grams,
                  thickness: (knit ? 0.0006 : 0.0003) * thick * (grams / (base * heavy)).squareRoot(),
                  friction: friction)
    }

    /// Folds a loose drape falls into around the body.
    var folds: Int { Int((4 + (1 - drape) * 7).rounded()) }
}

/// How a garment sits at each point, for the fit map, after CLO 3D's fit maps: 0 loose
/// (not touching), about 0.35 resting on the body, 0.6 tight (half the fabric's stretch
/// limit used), 1 very tight (at the limit), above that it can't stretch that far.
func fitValues(stretch: [Float], contact: [Bool], fabric: Fabric, neighbours: [[Int]]) -> [Float] {
    let raw = stretch.indices.map { i -> Float in
        let used = max(0, stretch[i] - 0.008) / fabric.stretchLimit
        return contact[i] ? max(0.35, 0.35 + used * 0.65) : min(used, 0.3)
    }
    // One smoothing pass, so single vertices don't speckle.
    var out = raw
    for i in raw.indices where !neighbours[i].isEmpty {
        var around: Float = 0
        for j in neighbours[i] { around += raw[j] }
        out[i] = 0.5 * raw[i] + 0.5 * around / Float(neighbours[i].count)
    }
    return out
}
