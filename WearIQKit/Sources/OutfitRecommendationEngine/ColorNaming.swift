import Foundation

extension ColorFamily {
    /// The named colour of a measured one (sRGB, 0…1), as a person would call it.
    ///
    /// Judged in CIELAB, where how colourful a shade is (chroma) is kept apart from how
    /// light it is: a dark khaki or bottle green indoors is still green, only darker, and
    /// is not called black just because its RGB values are small. Only a shade with
    /// almost no colour is black, grey or white, by its lightness. Coloured shades go to
    /// the nearest named one, with lightness counting half, so dark and light versions of
    /// a hue keep its name.
    public static func nearest(red r: Double, green g: Double, blue b: Double) -> ColorFamily {
        let c = Lab(r, g, b)
        let chroma = (c.a * c.a + c.b * c.b).squareRoot()
        if chroma < 6 + 0.06 * c.l {
            return c.l < 28 ? .black : (c.l > 84 ? .white : .gray)
        }
        var best = ColorFamily.gray, distance = Double.infinity
        for (family, rgb) in anchors {
            let a = Lab(rgb.0, rgb.1, rgb.2)
            let d = 0.25 * (a.l - c.l) * (a.l - c.l) + (a.a - c.a) * (a.a - c.a) + (a.b - c.b) * (a.b - c.b)
            if d < distance { distance = d; best = family }
        }
        return best
    }

    /// Typical shades of each coloured family, with their dark versions (as clothes
    /// look indoors).
    static let anchors: [(ColorFamily, (Double, Double, Double))] = [
        (.navy, (0.12, 0.16, 0.32)), (.navy, (0.07, 0.09, 0.18)),
        (.beige, (0.84, 0.76, 0.62)), (.beige, (0.70, 0.62, 0.50)), (.beige, (0.93, 0.89, 0.80)),
        (.brown, (0.45, 0.30, 0.20)), (.brown, (0.27, 0.18, 0.12)), (.brown, (0.60, 0.42, 0.28)),
        (.denim, (0.30, 0.42, 0.60)), (.denim, (0.20, 0.28, 0.42)), (.denim, (0.50, 0.62, 0.78)),
        (.blue, (0.15, 0.35, 0.80)), (.blue, (0.35, 0.60, 0.90)),
        (.green, (0.20, 0.55, 0.30)), (.green, (0.08, 0.24, 0.14)), (.green, (0.45, 0.75, 0.50)),
        (.olive, (0.42, 0.42, 0.22)), (.olive, (0.24, 0.25, 0.15)), (.olive, (0.52, 0.52, 0.38)),
        (.red, (0.80, 0.12, 0.12)), (.burgundy, (0.45, 0.08, 0.15)), (.burgundy, (0.28, 0.06, 0.09)),
        (.pink, (0.95, 0.60, 0.72)), (.pink, (0.85, 0.35, 0.55)),
        (.orange, (0.95, 0.50, 0.15)), (.yellow, (0.95, 0.85, 0.20)), (.yellow, (0.80, 0.68, 0.18)),
        (.purple, (0.50, 0.25, 0.60)), (.purple, (0.25, 0.12, 0.32)), (.purple, (0.72, 0.60, 0.85)),
    ]
}

/// CIELAB (D65) from sRGB.
private struct Lab {
    let l: Double, a: Double, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        func linear(_ v: Double) -> Double {
            let v = min(max(v, 0), 1)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let R = linear(r), G = linear(g), B = linear(b)
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        l = 116 * f(y) - 16
        a = 500 * (f(x) - f(y))
        self.b = 200 * (f(y) - f(z))
    }
}
