import Foundation

// MARK: Skin tone from the camera

/// Skin depth and undertone from the average colour of bare skin (forehead and cheeks)
/// in a photo taken in ordinary light.
///
/// Converted to CIELAB (D65), the Individual Typology Angle, ITA = atan((L* − 50) / b*),
/// is the dermatologists' measure of how light skin is: above 41° light, 28–41°
/// intermediate, 10–28° tan, below 10° brown/dark (Chardon et al. 1991). The hue angle
/// h = atan2(b*, a*) says how yellow (warm) or pink (cool) it is: skin runs from about
/// 45° (pink) to 70° (golden). Indoor light shifts it, so the scan asks for daylight and
/// says how sure it is.
public enum SkinToneAnalyzer {
    public struct Reading: Equatable, Sendable {
        public var depth: StyleProfile.SkinDepth
        public var undertone: StyleProfile.Undertone
        public var ita: Double
        public var hue: Double
    }

    /// From sRGB components 0–1.
    public static func classify(red: Double, green: Double, blue: Double) -> Reading {
        let (l, a, b) = lab(red, green, blue)
        let ita = atan2(l - 50, max(b, 0.001)) * 180 / .pi
        let hue = atan2(b, a) * 180 / .pi
        let depth: StyleProfile.SkinDepth = ita > 41 ? .light : ita > 28 ? .medium : ita > 10 ? .tan : .deep
        let undertone: StyleProfile.Undertone = hue >= 62 ? .warm : hue <= 54 ? .cool : .neutral
        return Reading(depth: depth, undertone: undertone, ita: ita, hue: hue)
    }

    static func lab(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }
}

// MARK: Advice

/// What to wear, for a body shape, the style the user likes, what they dress for and how
/// they like clothes to sit: whether the style suits the build and what would suit it
/// better, the cuts and fabrics to use. The app words each tip.
///
/// Sources: stylists' body-shape rules (balance the wider part, define the waist, long
/// vertical lines); fabric behaviour (stiff fabrics stand away from the body and add
/// volume, thin limp ones cling and show the shape; Univ. of Kentucky extension).
public struct StyleAdvice: Sendable, Equatable {
    public enum Occasion: String, Codable, CaseIterable, Sendable { case work, everyday, evening, active }
    public enum Ease: String, Codable, CaseIterable, Sendable { case fitted, relaxed }

    public enum Tip: String, Sendable, CaseIterable {
        // Cuts
        case vNeck, skimPastWaist, detailOnTop, straightBelow, softShoulders, volumeBelow
        case showWaist, createShape, relaxedBalance, fittedNoPull
        // Fabrics
        case fluidFabrics, structuredTopSoftBelow, softTops, stretchDrape, bodyFabrics
        case workFabrics, everydayFabrics, eveningFabrics, activeFabrics
        // Sparingly
        case stiffShinyOverMiddle, clingyOverHips, bulkyAcrossShoulders, boxyHidingWaist, limpFabrics
    }

    /// Whether the liked style suits the build (one of its two best).
    public var suitsChosen: Bool
    /// Styles that suit the build best, best first.
    public var bestVibes: [StyleProfile.Vibe]
    public var cuts: [Tip]
    public var fabrics: [Tip]
    public var sparingly: [Tip]

    public static func make(shape: BodyShape?, vibe: StyleProfile.Vibe, occasion: Occasion, ease: Ease) -> StyleAdvice {
        let best = vibes(for: shape, occasion: occasion)
        var cuts: [Tip], fabrics: [Tip], sparingly: [Tip]
        switch shape {
        case .apple?, .oval?:
            (cuts, fabrics, sparingly) = ([.vNeck, .skimPastWaist], [.fluidFabrics], [.stiffShinyOverMiddle])
        case .pear?, .triangle?:
            (cuts, fabrics, sparingly) = ([.detailOnTop, .straightBelow], [.structuredTopSoftBelow], [.clingyOverHips])
        case .invertedTriangle?:
            (cuts, fabrics, sparingly) = ([.softShoulders, .volumeBelow], [.softTops], [.bulkyAcrossShoulders])
        case .hourglass?:
            (cuts, fabrics, sparingly) = ([.showWaist], [.stretchDrape], [.boxyHidingWaist])
        case .rectangle?, nil:
            (cuts, fabrics, sparingly) = ([.createShape], [.bodyFabrics], [.limpFabrics])
        }
        cuts.append(ease == .relaxed ? .relaxedBalance : .fittedNoPull)
        let forOccasion: Tip = switch occasion {
        case .work: .workFabrics
        case .everyday: .everydayFabrics
        case .evening: .eveningFabrics
        case .active: .activeFabrics
        }
        fabrics.append(forOccasion)
        return StyleAdvice(suitsChosen: best.prefix(2).contains(vibe), bestVibes: best, cuts: cuts,
                           fabrics: fabrics, sparingly: sparingly)
    }

    /// Styles that suit a build and an occasion, best first.
    static func vibes(for shape: BodyShape?, occasion: Occasion) -> [StyleProfile.Vibe] {
        var order: [StyleProfile.Vibe]
        switch shape {
        case .apple?, .oval?: order = [.minimal, .classic, .casual, .bold]
        case .pear?, .triangle?: order = [.classic, .bold, .minimal, .casual]
        case .invertedTriangle?: order = [.casual, .minimal, .classic, .bold]
        case .hourglass?: order = [.classic, .bold, .minimal, .casual]
        case .rectangle?, nil: order = [.bold, .casual, .classic, .minimal]
        }
        // What the user dresses for weighs in: work leans classic, active casual.
        let lean: StyleProfile.Vibe? = switch occasion {
        case .work: .classic
        case .active: .casual
        case .evening: .bold
        case .everyday: nil
        }
        if let lean, let i = order.firstIndex(of: lean), i > 1 {
            order.remove(at: i)
            order.insert(lean, at: 1)
        }
        return order
    }
}
