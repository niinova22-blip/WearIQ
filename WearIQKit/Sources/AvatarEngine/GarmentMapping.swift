import FitEngine
import Foundation
import ProductMeasurementParser
import WearIQCore

/// Turns a garment's size chart into how it sits on the avatar: ease (garment minus
/// body girth) and how much longer or shorter than the body each length is. Garment
/// charts give the ease directly; body charts describe the body a size suits, so the
/// garment is taken as that body plus the usual ease for the fit (see EaseTable).
///
/// Whatever the chart leaves out is graded from what it gives (`Grading`): a size up is
/// bigger at the waist, thighs and knees as well as the chest or seat the chart lists,
/// and its sleeves and length are longer. The cut alone decides where a garment is
/// roomy or close by design.
public enum AvatarFitMapper {
    /// Thigh ease of a leg cut's usual size, cm, for charts without a thigh.
    public static func typicalThigh(_ cut: LegCut?) -> Double? {
        switch cut {
        case .skinny?: 2
        case .slim?, .flare?: 5
        case .straight?: 9
        case .tapered?: 12
        case .wide?: 18
        case nil: nil
        }
    }

    /// Seat ease of a trouser cut's usual size, cm.
    static func typicalHip(_ style: FitStyle, _ cut: LegCut?) -> Double {
        switch cut {
        case .skinny?: return 3
        case .wide?: return max(12, [FitStyle.slim: 4, .regular: 7, .relaxed: 12, .oversized: 20][style] ?? 7)
        case .tapered?: return max(9, [FitStyle.slim: 4, .regular: 7, .relaxed: 12, .oversized: 20][style] ?? 7)
        default: return [FitStyle.slim: 4, .regular: 7, .relaxed: 12, .oversized: 20][style] ?? 7
        }
    }

    /// Chest ease of a top's usual size for its cut, cm.
    static func typicalChest(_ spec: GarmentSpec) -> Double {
        let over: Double = spec.category == .coat ? 6 : 0
        return ([FitStyle.slim: 7, .regular: 12, .relaxed: 19, .oversized: 30][spec.fitStyle] ?? 12) + over
    }

    /// With `regions` (the size-chart verdicts for this size), the avatar's colours,
    /// lines and labels say what those verdicts say.
    public static func fit(spec: GarmentSpec, size: SizeEntry, body: BodyProfile, regions: [RegionFit] = [],
                           name: String? = nil) -> Avatar.GarmentFit {
        let isTrousers = spec.category == .pants
        let bottom = spec.category.isBottom
        var fit = Avatar.GarmentFit(kind: kind(spec, size))
        fit.style = switch spec.category {
        case .jacket: .jacket
        case .coat: .coat
        case .dress: .dress
        default: .plain
        }
        fit.judged = judged(regions, trousers: bottom)
        // The cut decides what counts as loose (an oversized tee is roomy by design) and,
        // for trousers, how the legs hang from the knee down.
        fit.cut = spec.fitStyle
        fit.legCut = bottom ? spec.legCut : nil
        let height = body[.height]?.cm ?? 170
        func diff(_ g: GarmentDimension, _ b: BodyDimension) -> Double? {
            guard let gv = size.values[g]?.cm, let bv = body[b]?.cm else { return nil }
            return gv - bv
        }
        /// The chart's ease for a girth, nil when the chart doesn't give it.
        func ease(_ g: GarmentDimension, _ b: BodyDimension, typical: Double) -> Double? {
            guard let d = diff(g, b) else { return nil }
            return spec.chartKind == .garment ? d : typical + d
        }
        let style = spec.fitStyle
        // A length the chart gives per size; one that is the same for every size says
        // nothing about this size (the chart doesn't grade it).
        func graded(_ g: GarmentDimension) -> Double? {
            guard let v = size.values[g]?.cm else { return nil }
            let all = spec.sizes.compactMap { $0.values[g]?.cm }
            return spec.sizes.count > 1 && all.count == spec.sizes.count && Set(all.map { ($0 * 2).rounded() }).count == 1 ? nil : v
        }
        // How far this size is from the cut's usual one on this body (+ bigger), in cm of
        // its primary girth: lengths and the girths the chart leaves out grow with it.
        var steps = 0.0
        // The design length the name says, cm from the kind's usual one.
        let words = SizeChartParser.foldForMatching(name ?? "")
        func hint(_ table: [(String, Double)]) -> Double { table.first { words.contains($0.0) }?.1 ?? 0 }
        // A skirt's or dress's shape below the hips is its cut: a pencil skirt hangs
        // straight down, an A-line opens out, a circle (kloş) or pleated one most.
        if spec.category == .skirt || spec.category == .dress {
            let padded = " " + words + " "
            if ["kalem", "pencil", "bodycon", "tube", "tup "].contains(where: padded.contains) {
                fit.flare = 0.02
            } else if ["klos", "circle", "pileli", "pleated", "volan", "ruffle"].contains(where: padded.contains) {
                fit.flare = 0.28
            } else if [" a kesim", "a-line", " a line ", "evase", "skater"].contains(where: padded.contains) {
                fit.flare = 0.2
            }
        }
        if spec.category == .skirt {
            fit.waistEase = ease(.waist, .waist, typical: 1.5) ?? 1.5
            steps = fit.waistEase - 1.5
            let hipTypical: Double = [FitStyle.slim: 5, .regular: 8, .relaxed: 16, .oversized: 30][style] ?? 8
            fit.hipEase = ease(.hip, .hip, typical: hipTypical) ?? hipTypical + steps * Grading.hipPerWaist
            // Waistband to hem; a regular skirt ends just above the knee.
            if let length = graded(.bodyLength) {
                fit.hemOffset = length - 0.245 * height
            } else {
                fit.lengthFromChart = false
                fit.hemOffset = hint([("mini", -0.065), ("midi", 0.15), ("maxi", 0.25), ("maksi", 0.25), ("uzun", 0.2)]) * height
                    + steps / 4
            }
        } else if bottom {
            // Trousers and shorts: sized by the waist; the seat, thighs and (on the avatar)
            // knees grow with it unless the chart says otherwise.
            fit.waistEase = ease(.waist, .waist, typical: 1.5) ?? 1.5
            let shortsHip: [FitStyle: Double] = [.slim: 4, .regular: 8, .relaxed: 14, .oversized: 22]
            let trouserThigh: [FitStyle: Double] = [.slim: 5, .regular: 9, .relaxed: 15, .oversized: 24]
            let shortsThigh: [FitStyle: Double] = [.slim: 6, .regular: 12, .relaxed: 20, .oversized: 30]
            let hipTypical = isTrousers ? typicalHip(style, spec.legCut) : shortsHip[style] ?? 8
            let thighTypical = isTrousers ? typicalThigh(spec.legCut) ?? trouserThigh[style] ?? 9 : shortsThigh[style] ?? 12
            let waistSteps = size.values[.waist] == nil ? nil : fit.waistEase - 1.5
            if let hip = ease(.hip, .hip, typical: hipTypical) {
                fit.hipEase = hip
            } else {
                fit.hipEase = hipTypical + (waistSteps ?? 0) * Grading.hipPerWaist
            }
            let seatSteps = size.values[.hip] != nil || waistSteps != nil ? fit.hipEase - hipTypical : 0
            if let thigh = ease(.thigh, .thigh, typical: thighTypical) {
                fit.thighEase = thigh
            } else {
                fit.thighEase = thighTypical + seatSteps * Grading.thighPerHip
            }
            if isTrousers {
                fit.lengthDelta = diff(.inseam, .inseam) ?? diff(.outseam, .outseam) ?? 0
            } else {
                // Legs end mid-thigh unless the chart gives the inseam ("bermuda" to the knee).
                fit.lengthFromChart = size.values[.inseam] != nil
                if let inseam = size.values[.inseam]?.cm, let body = body[.inseam]?.cm {
                    fit.hemOffset = inseam - body
                } else {
                    fit.hemOffset = -(words.contains("bermuda") ? 0.25 : 0.335) * height
                }
            }
        } else {
            let chestTypical = typicalChest(spec)
            fit.chestEase = ease(.chest, .chest, typical: chestTypical) ?? chestTypical
            steps = fit.chestEase - chestTypical
            let waistTypical = spec.category == .dress ? chestTypical - 4 : chestTypical + 3
            fit.waistEase = ease(.waist, .waist, typical: waistTypical) ?? waistTypical + steps * Grading.waistPerChest
            if spec.category == .dress {
                fit.hipEase = ease(.hip, .hip, typical: chestTypical - 2) ?? chestTypical - 2 + steps * Grading.waistPerChest
            } else {
                fit.hipEase = fit.waistEase
            }
            switch spec.category {
            case .coat, .dress:
                // Measured from the shoulder; a regular coat ends above the knee, a dress at
                // it. Its length is its style, so it moves the hem without being "too long".
                let regular = (spec.category == .coat ? 0.49 : 0.54) * height
                if let length = graded(.bodyLength), spec.chartKind == .garment {
                    fit.hemOffset = length - regular
                } else {
                    fit.lengthFromChart = false
                    let named = spec.category == .coat
                        ? hint([("uzun", 0.17), ("long", 0.17), ("maxi", 0.25), ("kisa", -0.12), ("short", -0.12)])
                        : hint([("mini", -0.095), ("midi", 0.12), ("maxi", 0.22), ("maksi", 0.22), ("uzun", 0.2)])
                    fit.hemOffset = named * height + steps * Grading.lengthPerChest
                }
            default:
                // Cut short or long by design: a crop top ends about the navel, a longline
                // or oversize one a hand lower than usual.
                fit.hemOffset = hint([("crop", -0.075), ("longline", 0.06), ("uzun", 0.05), ("oversize", 0.03)]) * height
                let lengthEase: Double = spec.category == .tshirt ? 18 : spec.category == .jacket ? 25 : 21
                if graded(.bodyLength) != nil, let d = diff(.bodyLength, .torsoLength) {
                    fit.lengthDelta = spec.chartKind == .garment ? d - lengthEase : d
                } else {
                    fit.lengthFromChart = false
                    fit.lengthDelta = steps * Grading.lengthPerChest
                    fit.judged.length = nil
                }
            }
            if graded(.sleeveLength) != nil, let d = diff(.sleeveLength, .armLength) {
                fit.sleeveDelta = spec.chartKind == .garment ? d - 2.5 : d
            } else {
                fit.sleeveFromChart = false
                fit.sleeveDelta = steps * Grading.sleevePerChest
                fit.judged.sleeve = nil
            }
            // The chart's shoulder runs over the back; a scanned one is bone to bone.
            let shoulder = body[.shoulderWidth].map(FitEngine.acrossBack)
            if let gv = size.values[.shoulderWidth]?.cm, let bv = shoulder?.cm {
                let d = gv - bv
                fit.shoulderDelta = spec.chartKind == .garment ? d : d + (style == .oversized ? 7 : 0)
            } else {
                // No shoulder on the chart: shoulders are graded with the chest, so a size
                // cut roomier than a regular fit of this kind on this body has its seams that
                // much further out, and a smaller one further in.
                fit.shoulderDelta = steps * Grading.shoulderPerChest + (style == .oversized ? 7 : 0)
            }
        }
        return fit
    }

    /// The avatar's garment for a category: sleeves from the category, or for a dress from
    /// the chart (a sleeve over 30 cm is a long one).
    public static func kind(_ spec: GarmentSpec, _ size: SizeEntry) -> Avatar.GarmentFit.Kind {
        switch spec.category {
        case .pants, .shorts: .trousers
        case .skirt: .skirt
        case .tshirt: .top(longSleeves: false)
        case .dress: .top(longSleeves: (size.values[.sleeveLength]?.cm ?? 0) > 30)
        case .shirt, .jacket, .coat, .sweater: .top(longSleeves: true)
        }
    }

    /// The verdicts the avatar shows: how far each length is past the usual range, where
    /// the shoulder seams sit, how the trouser waist sits. Nil where there's no verdict,
    /// and the avatar judges by its own drape.
    ///
    /// A zone the chart doesn't measure takes the verdict of the one it is graded from:
    /// trouser thighs the seat's, and a loose thigh makes loose knees and hems (the whole
    /// leg is cut from it); a loose chest makes loose sleeves.
    public static func judged(_ regions: [RegionFit], trousers: Bool) -> Avatar.GarmentFit.Judged {
        var j = Avatar.GarmentFit.Judged()
        func by(_ r: FitRegion) -> RegionFit? { regions.first { $0.region == r && $0.verdict != .insufficientData } }
        func length(_ r: RegionFit?) -> Double? {
            guard let r else { return nil }
            let amount = max(1, r.estimatedOffsetCm.map { ($0.lowerBound + $0.upperBound) / 2 } ?? 1)
            switch r.verdict {
            case .long: return amount
            case .short: return -amount
            default: return 0
            }
        }
        // Each girth verdict for the zones it covers: loose, fits or tight there.
        func tone(_ r: RegionFit) -> FitTone {
            switch r.verdict {
            case .tight, .slightlyTight: .tight
            case .loose, .slightlyLoose: .loose
            default: .fits
            }
        }
        func tension(_ r: RegionFit) -> ZoneTension {
            switch r.verdict {
            case .tight: .tight
            case .slightlyTight: .slightlyTight
            case .loose, .slightlyLoose: .loose
            default: .comfortable
            }
        }
        var covered: [(RegionFit, [FitZone])] = []
        if trousers {
            if let w = by(.waist) { covered.append((w, [.waist])) }
            let seat = by(.hip)
            if let seat { covered.append((seat, [.hip])) }
            if let thigh = by(.thigh) ?? seat {
                covered.append((thigh, [.thigh]))
                if tone(thigh) == .loose { covered.append((thigh, [.knee, .hem])) }
            }
        } else {
            if let chest = by(.chest) {
                covered.append((chest, [.chest, .back]))
                if tone(chest) == .loose { covered.append((chest, [.sleeve, .elbow])) }
            }
            if let waist = by(.waist) ?? by(.chest) { covered.append((waist, [.waist, .abdomen, .hip])) }
        }
        for (r, zones) in covered {
            for zone in zones {
                j.zones[zone] = tone(r)
                j.tensions[zone] = tension(r)
            }
        }
        if trousers {
            j.length = length(by(.inseam) ?? by(.outseam))
            if let w = by(.waist) {
                switch w.verdict {
                case .tight, .slightlyTight: j.waist = .tight
                case .loose, .slightlyLoose: j.waist = .loose
                default: j.waist = .fits
                }
            }
        } else {
            j.length = length(by(.bodyLength))
            j.sleeve = length(by(.sleeve))
            if let s = by(.shoulder) {
                // Half the width difference falls on each side, as the verdict's own
                // wording ("shoulder seams sit about 4 cm low") says.
                switch s.verdict {
                case .ideal: j.shoulderPerSide = 0
                case .slightlyLoose, .loose: if let e = s.easeCm, e > 0 { j.shoulderPerSide = e / 2 }
                case .slightlyTight, .tight: if let e = s.easeCm, e < 0 { j.shoulderPerSide = e / 2 }
                default: break
                }
            }
        }
        return j
    }

    /// How the fabric stretches and drapes, from its composition when the product page
    /// gave one, otherwise from the category and the chart's stretch setting.
    public static func fabric(spec: GarmentSpec, material: String?) -> Fabric {
        let knit = spec.category == .tshirt || spec.category == .sweater
        let fibres = FabricAdvice.fibres(in: material ?? "")
        guard !fibres.isEmpty else {
            var fabric: Fabric = spec.category.isOuterwear ? .outerwear : knit ? .knit : .woven
            fabric.stretchLimit += Float(spec.stretch.comfortableStretch)
            return fabric
        }
        let mix = Dictionary(uniqueKeysWithValues: fibres.map { ($0.key.rawValue, $0.value) })
        // A jacket or coat is a heavy cloth whatever it's made of.
        return spec.category.isOuterwear ? Fabric(fibres: mix, knit: false, weight: 300) : Fabric(fibres: mix, knit: knit)
    }

    /// The body at the low and high ends of its measured ranges, where those are wider
    /// than a few centimetres (clothes hid it); nil ends where the scan is sure.
    public static func bodyRange(_ body: BodyProfile, around m: Avatar.Measurements) -> (Avatar.Measurements?, Avatar.Measurements?) {
        func ends(_ d: BodyDimension) -> (Double, Double)? {
            guard let a = body.assessment(d), a.high - a.low > 4 else { return nil }
            return (a.low, a.high)
        }
        let dims: [BodyDimension] = [.chest, .waist, .hip, .thigh]
        guard dims.contains(where: { ends($0) != nil }) else { return (nil, nil) }
        let low = m.with(chest: ends(.chest)?.0, waist: ends(.waist)?.0, hip: ends(.hip)?.0, thigh: ends(.thigh)?.0)
        let high = m.with(chest: ends(.chest)?.1, waist: ends(.waist)?.1, hip: ends(.hip)?.1, thigh: ends(.thigh)?.1)
        return (low, high)
    }
}
