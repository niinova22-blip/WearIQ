import Foundation

/// A part of a draped garment judged on its own in the fit report.
public enum FitZone: String, CaseIterable, Sendable {
    case shoulder, chest, back, waist, abdomen, sleeve, elbow, hip, thigh, knee, hem
}

/// How a zone sits, after the fit map's colours: blue loose, green comfortable, yellow
/// slightly tight, orange tight, red very tight.
public enum ZoneTension: Int, Comparable, CaseIterable, Sendable {
    case loose, comfortable, slightlyTight, tight, veryTight

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// One zone of a simulated garment, from the drape itself.
public struct ZoneReport: Equatable, Sendable {
    public var zone: FitZone
    public var tension: ZoneTension
    /// 75th percentile of the stretch past the cut where the fabric presses on the body,
    /// round the body (not along it), per cent.
    public var stretchPercent: Double
    /// That stretch over what the fabric takes comfortably (1 = at the limit).
    public var stretchUsed: Double
    /// Share of the zone resting on the body.
    public var contactShare: Double
    /// Median distance from the skin where it doesn't touch, cm.
    public var gapCm: Double
    /// Median girth ease the zone is cut with, cm (garment less body girth).
    public var easeCm: Double = 0
    /// Garment longer (+) or shorter (−) than the body there, cm, for sleeves and hems.
    public var lengthDeltaCm: Double?
}

extension ZoneReport {
    /// The verdict from the numbers: how much of its comfortable stretch the fabric uses
    /// (under 0.3 comfortable, 0.6 slightly tight, 1 tight, beyond it very tight), or
    /// loose. With a girth ease and the zone's loose threshold (see
    /// `BodyModel.looseEase`), loose is more ease than that, as a tape would find; without
    /// them, most of the zone standing off the body by more than 1.5 cm.
    static func classify(stretchUsed u: Double, contactShare: Double, gapCm: Double,
                         easeCm: Double? = nil, looseAbove: Double? = nil) -> ZoneTension {
        if u >= 1 { return .veryTight }
        if u >= 0.6 { return .tight }
        if u >= 0.3 { return .slightlyTight }
        if let easeCm, let looseAbove { return easeCm > looseAbove ? .loose : .comfortable }
        if contactShare < 0.3, gapCm > 1.5 { return .loose }
        return .comfortable
    }
}

extension BodyModel {
    /// Which zone a garment vertex belongs to, from where it was cut (`rest`) and which
    /// part it belongs to (0 the body part, then the sleeves or trouser legs).
    func zone(of rest: Vec3, part: Int, kind: Avatar.GarmentFit.Kind) -> FitZone {
        let y = rest.y
        switch kind {
        case .trousers:
            if part == 0 { return y >= (waistY + hipY) / 2 - 0.04 * h ? .waist : .hip }
            if y >= kneeY + 0.06 * h { return .thigh }
            if y >= kneeY - 0.06 * h { return .knee }
            return .hem
        case .skirt:
            if y >= (waistY + hipY) / 2 - 0.04 * h { return .waist }
            if y >= crotchY { return .hip }
            if y >= kneeY + 0.06 * h { return .thigh }
            return .hem
        case .top:
            if part > 0 {
                let arm = arms[part - 1]
                let along = (rest - arm.start).dot(arm.dir) / armLength
                return abs(along - 0.55) < 0.08 ? .elbow : .sleeve
            }
            let front = rest.z >= torso.ring(at: y).center.z
            if y >= shoulderY - 0.03 * h { return .shoulder }
            if y >= (waistY + chestY) / 2 { return front ? .chest : .back }
            if y >= waistY - 0.03 * h { return .waist }
            return front ? .abdomen : .hip
        }
    }

    /// A sleeve past the wrist, lying on the hand: the hand stretches it, which says
    /// nothing about the fit (a long sleeve read "very tight" from this).
    func onHand(_ rest: Vec3, part: Int, kind: Avatar.GarmentFit.Kind) -> Bool {
        guard case .top = kind, part > 0, part <= arms.count else { return false }
        let arm = arms[part - 1]
        return (rest - arm.start).dot(arm.dir) > armLength - 0.02
    }

    /// Whether the drape's stretch can say a part is tight. Not a sleeve: size charts
    /// give no sleeve width, so a sleeve is always cut with room round the arm, and what
    /// stretches it in the drape is its own weight hanging off an arm held out (every
    /// long sleeve read "very tight, 14–17%" on the phone, even in XXL).
    func stretchCounts(part: Int, kind: Avatar.GarmentFit.Kind) -> Bool {
        if case .top = kind, part > 0 { return false }
        return true
    }

    func report(_ cloth: TriangleCloth, contact pressing: [Bool], ease: [Float], tags: [Int], fit: Avatar.GarmentFit,
                fabric: Fabric) -> [FitZone: ZoneReport] {
        var members: [FitZone: [Int]] = [:]
        for i in cloth.rest.indices {
            members[zone(of: cloth.rest[i], part: tags[i], kind: fit.kind), default: []].append(i)
        }
        var out: [FitZone: ZoneReport] = [:]
        for (zone, ids) in members where ids.count >= 6 {
            // Only fabric held against the body is pulled by it: loose fabric stretches a
            // little under its own weight (a trouser leg hanging from the seat), which is
            // no tightness. As in the fit map, which colours only touching fabric tight.
            // A trouser hem resting on the foot isn't a fit problem either (no shoes).
            let trousers = fit.kind.isBottom
            let touching = ids.filter { pressing[$0] && !(trousers && cloth.rest[$0].y < ankleY + 0.015)
                && stretchCounts(part: tags[$0], kind: fit.kind) }
            let stretch = touching.map { Double(cloth.stretch[$0]) }.sorted()
            // The 75th percentile: a garment pulled round the body stretches all over the
            // zone, while a few edges caught in a fold or on a bony point (the kneecap)
            // stretch alone, and that isn't the zone being tight.
            let p90 = touching.count * 10 >= ids.count && !stretch.isEmpty
                ? stretch[min(stretch.count - 1, Int(Double(stretch.count) * 0.75))] : 0
            // The first 0.8% is the mesh settling, not the fabric pulling (as in the fit map).
            let used = max(0, p90 - 0.008) / Double(fabric.stretchLimit)
            let contact = Double(ids.filter { pressing[$0] }.count) / Double(ids.count)
            let gaps = ids.filter { !cloth.contact[$0] }.map { Double(cloth.gap[$0]) * 100 }.sorted()
            let gap = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
            var length: Double?
            switch (zone, fit.kind) {
            case (.sleeve, .top(longSleeves: true)): length = fit.sleeveDelta
            case (.hem, .trousers), (.hem, .skirt), (.abdomen, .top), (.hip, .top): length = fit.lengthDelta
            default: length = nil
            }
            let eases = ids.map { Double(ease[$0]) }.sorted()
            let zoneEase = eases[eases.count / 2]
            // Trouser knees and hems hang off the leg as they're cut: never "loose".
            // Nor sleeves: they hang off an arm held out, and the chart has no sleeve width.
            let sleeve = zone == .sleeve || zone == .elbow
            let threshold = Self.looseEase(zone, fit.kind, style: fit.style).map(Double.init)
                ?? (trousers || sleeve ? .infinity : nil)
            var tension = ZoneReport.classify(stretchUsed: used, contactShare: contact, gapCm: gap,
                                              easeCm: threshold == nil ? nil : zoneEase, looseAbove: threshold)
            // Where the size chart judged the zone, the report says the same; only a
            // stretch past the fabric's limit there can make a tight verdict "very tight".
            if let judged = fit.judged.tensions[zone] {
                tension = tension == .veryTight && judged >= .tight ? .veryTight : judged
            }
            var report = ZoneReport(zone: zone,
                                    tension: tension,
                                    stretchPercent: p90 * 100, stretchUsed: used, contactShare: contact, gapCm: gap,
                                    lengthDeltaCm: length)
            report.easeCm = zoneEase
            out[zone] = report
        }
        return out
    }
}

// MARK: - Uncertain bodies and sizes

extension Avatar.Measurements {
    /// The same person with girths at other values: what a garment of fixed size meets
    /// if the body is at the low or high end of what the scan allows.
    public func with(chest: Double? = nil, waist: Double? = nil, hip: Double? = nil, thigh: Double? = nil) -> Self {
        var m = self
        if let chest { m.chest = chest }
        if let waist { m.waist = waist }
        if let hip { m.hip = hip }
        if let thigh { m.thigh = thigh }
        return m
    }
}

extension Avatar.GarmentFit {
    /// The same garment on a body whose girths differ: the garment doesn't change, so
    /// its ease shrinks by however much the body grew.
    public func on(_ other: Avatar.Measurements, insteadOf body: Avatar.Measurements) -> Self {
        var f = self
        f.chestEase -= other.chest - body.chest
        f.waistEase -= other.waist - body.waist
        f.hipEase -= other.hip - body.hip
        f.thighEase -= other.thigh - body.thigh
        return f
    }
}

/// One size draped on the body as measured and, where the body is uncertain, on the
/// smaller and larger bodies the scan allows.
public struct SizeDrape: Sendable {
    public var label: String
    /// On the body as measured.
    public var zones: [FitZone: ZoneReport]
    /// Per zone, the loosest and tightest verdict over the bodies tried; equal ends when
    /// the body is certain there or only one body was tried.
    public var range: [FitZone: ClosedRange<ZoneTension>]
    /// The avatar as measured, for display.
    public var avatar: Avatar

    /// Zones whose verdict depends on where in its range the body really is.
    public var uncertainZones: [FitZone] {
        range.filter { $0.value.lowerBound != $0.value.upperBound }.map(\.key).sorted { $0.rawValue < $1.rawValue }
    }

    /// How badly it fits, for ranking sizes: tightness costs more than looseness (a tight
    /// garment can't be fixed), very tight most; averaged over the bodies tried.
    public var cost: Double {
        zones.values.reduce(0) { sum, z in
            let r = range[z.zone] ?? (z.tension...z.tension)
            return sum + (Self.cost(r.lowerBound) + 2 * Self.cost(z.tension) + Self.cost(r.upperBound)) / 4
        }
    }

    static func cost(_ t: ZoneTension) -> Double {
        switch t {
        case .comfortable: 0
        case .loose: 0.6
        case .slightlyTight: 0.4
        case .tight: 2
        case .veryTight: 5
        }
    }
}

extension Avatar {
    /// Drapes each size on the body; with `low` and `high` (the body at the ends of its
    /// measurement ranges) also on those, so a verdict that depends on an uncertain girth
    /// shows as a range instead of a certainty.
    public static func compare(sizes: [(label: String, fit: GarmentFit)], body: Measurements,
                               low: Measurements? = nil, high: Measurements? = nil,
                               detail: Detail = .preview) -> [SizeDrape] {
        sizes.map { size in
            let main = Avatar(body, garment: size.fit, detail: detail)
            var range = main.fitReport.mapValues { $0.tension...$0.tension }
            for other in [low, high].compactMap({ $0 }) where other != body {
                let variant = Avatar(other, garment: size.fit.on(other, insteadOf: body), detail: detail)
                for (zone, r) in variant.fitReport {
                    let current = range[zone] ?? (r.tension...r.tension)
                    range[zone] = min(current.lowerBound, r.tension)...max(current.upperBound, r.tension)
                }
            }
            return SizeDrape(label: size.label, zones: main.fitReport, range: range, avatar: main)
        }
    }

    /// The size whose drape fits best, or nil when nothing was draped.
    public static func best(_ drapes: [SizeDrape]) -> SizeDrape? {
        drapes.min { $0.cost < $1.cost }
    }
}
