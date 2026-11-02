import FitEngine
import Foundation
import ProductMeasurementParser
import Testing
@testable import AvatarEngine
import WearIQCore

/// The 400 shoppers of `Population` (200 men, 200 women; soldiers and civilians, BMI 17
/// to 60, 18 to 79 years, every body shape the charts know) each buy ten garments of
/// every kind (tees, shirts, jumpers, jackets, coats, dresses, skirts, trousers of every
/// leg cut, shorts) in every fabric stretch, from three kinds of store: one with a
/// garment (flat-measured) chart, one with a body chart (letter, EU or inch sizes, plus
/// sizes included), one with no chart where only the model's size and height are known.
///
/// What a shopper needs from the app to trust it with a purchase (docs/VALIDATION.md
/// §15 has the research behind this):
///
/// - **No contradictions.** A bigger size is never tighter or shorter anywhere; the
///   avatar grades with the size and shows what the chart says; the cut note
///   recommends the size the result does.
/// - **The right size, said plainly.** The recommended size isn't tight at the chest
///   (tops) or waist (bottoms) while a bigger one fits; isn't loose there while a
///   smaller one fits; is near the body on a body chart.
/// - **Honest when it can't be sure.** A recommendation is never "high confidence" in a
///   size that is tight where it matters; a body no size fits is told so; the app
///   working only from height and weight, or from a scan, is seldom confidently wrong
///   (it says "between sizes" or lowers its confidence instead).
/// - **It responds as a fitting room would.** Wanting it snugger never gives a bigger
///   size, looser never smaller; stretch fabric never asks for a bigger size; a bigger
///   body never gets a smaller one.
///
/// `AUDIT_REPORT=path` writes every finding and the per-group numbers out.
@Suite struct PopulationAudit {
    typealias Shopper = Population.Shopper

    struct Product {
        var name: String
        var store: String
        var spec: GarmentSpec
    }

    /// SplitMix64: the same products on every run.
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + unit() * (r.upperBound - r.lowerBound) }
    }

    /// What each shopper likes: cuts of tops and trousers.
    static func taste(_ s: Shopper) -> (tops: FitStyle, legs: LegCut?) {
        var rng = RNG(state: UInt64(s.id) &* 7919 &+ 11)
        let tops: FitStyle = rng.pick([.slim, .regular, .regular, .relaxed, .oversized])
        let legs: LegCut? = rng.pick(s.sex == .female ? [.skinny, .straight, .wide, .flare, .tapered, nil]
                                                      : [.skinny, .slim, .straight, .tapered, .wide, nil])
        return (tops, legs)
    }

    // MARK: Products

    static func letterLabels(_ sex: BodySex) -> [String] {
        sex == .male ? ["S", "M", "L", "XL", "2XL", "3XL", "4XL", "5XL"] : ["XS", "S", "M", "L", "XL", "2XL", "3XL", "4XL"]
    }

    static func mv(_ x: Double, _ u: Double = 0.5) -> MeasuredValue { MeasuredValue(cm: x, uncertaintyCm: u, source: .manual) }

    /// A store's flat-measured chart for a top, graded as patterns are.
    static func garmentTop(_ category: GarmentCategory, _ fit: FitStyle, _ sex: BodySex, stretch: FabricStretch,
                           rng: inout RNG) -> GarmentSpec {
        let labels = letterLabels(sex)
        let mIndex = sex == .male ? 1 : 2
        // An M's body: men chest 100, women bust 90.
        let body = sex == .male ? 100.0 : 90
        let over: Double = category == .coat ? 6 : 0
        let ease: Double = over + {
            switch fit {
            case .slim: 7
            case .regular: 13
            case .relaxed: 19
            case .oversized: 30
            }
        }()
        let step = sex == .male ? rng.range(6...8) : rng.range(4...6)
        let brand = rng.range(-3...3)
        var length: Double = switch category {
        case .tshirt: sex == .male ? 71 : 62
        case .coat: sex == .male ? 100 : 95
        case .dress: rng.range(88...118)
        default: sex == .male ? 74 : 64
        }
        if fit == .oversized { length += 3 }
        let sleeve: Double = sex == .male ? 63 : 59
        let shoulder: Double = (sex == .male ? 46 : 39) + (fit == .oversized ? 8 : fit == .relaxed ? 3 : fit == .slim ? -1 : 0)
            + (category.isOuterwear ? 1.5 : 0)
        let sizes = labels.enumerated().map { i, label -> SizeEntry in
            let k = Double(i - mIndex)
            var v: [GarmentDimension: MeasuredValue] = [
                .chest: mv(body + ease + brand + k * step),
                .bodyLength: mv(length + k * step * 0.35),
                .shoulderWidth: mv(shoulder + k * step * 0.25),
            ]
            if category != .tshirt {
                // Oversized cuts drop the shoulder and shorten the sleeve to match.
                v[.sleeveLength] = mv(sleeve - (fit == .oversized ? 5 : 0) + k * step * 0.2)
                v[.waist] = mv(body + ease + brand + k * step - (fit == .slim ? 6 : 2))
            }
            if category == .dress {
                v[.waist] = mv(body - 16 + ease * 0.6 + brand + k * step)
                v[.hip] = mv(body + 8 + ease * 0.7 + brand + k * step)
                v[.sleeveLength] = nil
            }
            return SizeEntry(label: label, values: v)
        }
        return GarmentSpec(category: category, fitStyle: fit, stretch: stretch,
                           thickness: category.isOuterwear ? .thick : category == .sweater ? .medium : .thin,
                           chartKind: .garment, sizes: sizes)
    }

    /// A store's flat-measured chart for trousers or shorts (waist inches for men, EU
    /// for women).
    static func garmentTrousers(_ category: GarmentCategory, _ cut: LegCut?, _ sex: BodySex, stretch: FabricStretch,
                                rng: inout RNG) -> GarmentSpec {
        let labels: [String] = sex == .male ? ["28", "30", "32", "34", "36", "38", "40", "42", "44", "46"]
                                            : ["34", "36", "38", "40", "42", "44", "46", "48", "50", "52"]
        let fit = cut?.impliedFit ?? .regular
        let (hipEase, thighRatio): (Double, Double) = switch cut {
        case .skinny?: (2, 0.53)
        case .slim?, .flare?: (5, 0.57)
        case .straight?: (8, 0.61)
        case .tapered?: (11, 0.62)
        case .wide?: (16, 0.68)
        case nil: (7, 0.6)
        }
        let brand = rng.range(-1...1)
        let sizes = labels.map { label -> SizeEntry in
            let n = Double(label)!
            let waist = sex == .male ? n * 2.54 + 1 : 70 + (n - 38) * 2
            let bodyHip = sex == .male ? waist + 17 : waist + 26
            let hip = bodyHip + hipEase
            var v: [GarmentDimension: MeasuredValue] = [.waist: mv(waist + brand), .hip: mv(hip), .thigh: mv(hip * thighRatio)]
            if category == .pants { v[.inseam] = mv(sex == .male ? 81.0 : 78) }
            return SizeEntry(label: label, values: v)
        }
        return GarmentSpec(category: category, fitStyle: fit, stretch: stretch, chartKind: .garment, sizes: sizes,
                           legCut: category == .pants ? cut : nil)
    }

    /// A skirt's flat-measured chart, EU sizes.
    static func garmentSkirt(_ fit: FitStyle, stretch: FabricStretch, rng: inout RNG) -> GarmentSpec {
        let hipEase: Double = switch fit {
        case .slim: 4
        case .regular: 8
        case .relaxed: 16
        case .oversized: 30
        }
        let brand = rng.range(-1...1)
        let sizes = ["34", "36", "38", "40", "42", "44", "46", "48", "50", "52"].map { label -> SizeEntry in
            let n = Double(label)!
            let waist = 70 + (n - 38) * 2 + brand
            return SizeEntry(label: label, values: [.waist: mv(waist + 1), .hip: mv(waist + 26 + hipEase)])
        }
        return GarmentSpec(category: .skirt, fitStyle: fit, stretch: stretch, chartKind: .garment, sizes: sizes)
    }

    static func chartLabels(_ category: GarmentCategory, _ sex: BodySex, rng: inout RNG) -> [String] {
        if category.isBottom && sex == .male { return ["28", "30", "32", "34", "36", "38", "40", "42", "44", "46"] }
        // Half the women's stores size in EU numbers.
        if sex == .female && rng.unit() < 0.5 { return ["34", "36", "38", "40", "42", "44", "46", "48", "50", "52"] }
        return letterLabels(sex)
    }

    /// A store's body chart (the body each size suits), shifted a little by brand.
    static func bodyChart(_ category: GarmentCategory, _ fit: FitStyle, _ sex: BodySex, cut: LegCut?, stretch: FabricStretch,
                          rng: inout RNG) -> GarmentSpec? {
        let labels = chartLabels(category, sex, rng: &rng)
        guard var chart = StandardSizeCharts.chart(for: labels, category: category, audience: sex == .male ? .men : .women) else { return nil }
        let shift = rng.range(-3...3)
        for i in chart.sizes.indices {
            for (d, v) in chart.sizes[i].values {
                chart.sizes[i].values[d] = MeasuredValue(cm: v.cm + shift, uncertaintyCm: 2, source: .manual)
            }
        }
        return GarmentSpec(category: category, fitStyle: fit, stretch: stretch, chartKind: .body, sizes: chart.sizes,
                           legCut: category == .pants ? cut : nil)
    }

    /// No chart: the standard one, anchored to the model's size and height.
    static func modelChart(_ category: GarmentCategory, _ fit: FitStyle, _ sex: BodySex, cut: LegCut?, stretch: FabricStretch,
                           rng: inout RNG) -> GarmentSpec? {
        let labels = chartLabels(category, sex, rng: &rng)
        let worn = labels.contains("M") ? (sex == .male ? "M" : "S") : sex == .male ? "32" : "36"
        let height = sex == .male ? rng.range(182...190) : rng.range(172...179)
        let anchor = ModelFit(size: worn, heightCm: height, chestCm: rng.unit() < 0.5 && category.isTop ? (sex == .male ? 98 : 84) : nil)
        guard let chart = StandardSizeCharts.chart(for: labels, category: category, audience: sex == .male ? .men : .women,
                                                   anchor: anchor) else { return nil }
        return GarmentSpec(category: category, fitStyle: fit, stretch: stretch, chartKind: chart.kind ?? .body, sizes: chart.sizes,
                           legCut: category == .pants ? cut : nil)
    }

    static func products(for s: Shopper, rng: inout RNG) -> [Product] {
        var out: [Product] = []
        let (tops, legs) = taste(s)
        let topKinds: [GarmentCategory] = s.sex == .male ? [.tshirt, .shirt, .sweater, .jacket, .coat]
                                                         : [.tshirt, .shirt, .sweater, .jacket, .coat, .dress]
        let bottomKinds: [GarmentCategory] = s.sex == .male ? [.pants, .pants, .shorts] : [.pants, .pants, .shorts, .skirt]
        func add(_ c: GarmentCategory, fit: FitStyle, cut: LegCut?) {
            let stretch: FabricStretch = cut == .skinny ? rng.pick([.medium, .high])
                : c == .sweater ? rng.pick([.low, .medium]) : rng.pick([.none, .none, .low, .medium])
            let name = c.isBottom && c != .skirt ? "\(cut?.rawValue ?? "regular") \(c)" : "\(fit) \(c)"
            switch rng.next() % 3 {
            case 0:
                let spec = c == .skirt ? garmentSkirt(fit, stretch: stretch, rng: &rng)
                    : c.isBottom ? garmentTrousers(c, cut, s.sex, stretch: stretch, rng: &rng)
                    : garmentTop(c, fit, s.sex, stretch: stretch, rng: &rng)
                out.append(Product(name: name, store: "garment chart", spec: spec))
            case 1:
                if let spec = bodyChart(c, fit, s.sex, cut: cut, stretch: stretch, rng: &rng) {
                    out.append(Product(name: name, store: "body chart", spec: spec))
                }
            default:
                if let spec = modelChart(c, fit, s.sex, cut: cut, stretch: stretch, rng: &rng) {
                    out.append(Product(name: name, store: "model only", spec: spec))
                }
            }
        }
        for _ in 0..<6 {
            add(rng.pick(topKinds), fit: rng.unit() < 0.7 ? tops : rng.pick(FitStyle.allCases), cut: nil)
        }
        for _ in 0..<4 {
            let c = rng.pick(bottomKinds)
            let cut = rng.unit() < 0.7 ? legs : rng.pick(LegCut.allCases)
            add(c, fit: c == .skirt ? rng.pick([.slim, .regular, .relaxed]) : cut?.impliedFit ?? .regular, cut: c == .pants ? cut : nil)
        }
        return out
    }

    // MARK: Checks

    struct Findings {
        var items: [String: [String]] = [:]
        var checks = 0
        mutating func check(_ ok: Bool, _ kind: String, _ detail: @autoclosure () -> String) {
            checks += 1
            if !ok { items[kind, default: []].append(detail()) }
        }
        var total: Int { items.values.map(\.count).reduce(0, +) }
        var summary: String {
            items.keys.sorted().map { "\($0): \(items[$0]!.count)\n  " + items[$0]!.prefix(4).joined(separator: "\n  ") }
                .joined(separator: "\n")
        }
    }

    static func rank(_ v: FitVerdict) -> Int? {
        switch v {
        case .tight: 0
        case .slightlyTight: 1
        case .ideal: 2
        case .slightlyLoose: 3
        case .loose: 4
        case .short: 0
        case .long: 4
        case .insufficientData: nil
        }
    }

    /// The sizes a recommendation names, as chart indices.
    static func picks(_ a: FitAnalysis) -> Set<Int> {
        switch a.recommendation {
        case let .size(label, _): Set(a.sizes.indices.filter { a.sizes[$0].label == label })
        case let .between(s, l): Set(a.sizes.indices.filter { a.sizes[$0].label == s || a.sizes[$0].label == l })
        case .insufficientData: []
        }
    }

    static func critical(_ spec: GarmentSpec) -> FitRegion { spec.category.isBottom ? .waist : .chest }

    static func fitsAtCritical(_ size: SizeFit, _ region: FitRegion) -> Bool {
        size.region(region).map { [.ideal, .slightlyLoose, .slightlyTight].contains($0.verdict) } ?? false
    }

    /// Everything about one shopper and one garment.
    static func audit(_ s: Shopper, _ p: Product, into f: inout Findings, stats: inout Stats) {
        let body = s.body(s.scanned ? .scan : .tape)
        let engine = FitEngine()
        let analysis = engine.analyze(body: body, garment: p.spec)
        let tag = "#\(s.id) \(s.sex) \(s.origin) BMI \(Int(s.bmi)) \(p.name) [\(p.store)]"
        let bottom = p.spec.category.isBottom
        let crit = critical(p.spec)

        // 1. A bigger size is never tighter nor shorter in any region.
        var last: [FitRegion: Int] = [:]
        for size in analysis.sizes {
            for r in size.regions {
                guard let k = rank(r.verdict) else { continue }
                if let before = last[r.region] {
                    f.check(k >= before, "bigger size tighter or shorter", "\(tag) \(r.region) at \(size.label): \(r.verdict)")
                }
                last[r.region] = k
            }
        }

        // 2. The avatar grades with the size and says what the chart says.
        var previous: Avatar.GarmentFit?
        for (entry, size) in zip(p.spec.sizes, analysis.sizes) {
            let fit = AvatarFitMapper.fit(spec: p.spec, size: entry, body: body, regions: size.regions)
            if let prev = previous {
                let eps = 0.01
                if bottom {
                    f.check(fit.waistEase >= prev.waistEase - eps, "avatar not graded", "\(tag) waist \(entry.label)")
                    f.check(fit.hipEase >= prev.hipEase - eps, "avatar not graded", "\(tag) hip \(entry.label)")
                    if fit.kind == .trousers {
                        f.check(fit.thighEase >= prev.thighEase - eps, "avatar not graded", "\(tag) thigh \(entry.label)")
                    }
                } else {
                    f.check(fit.chestEase >= prev.chestEase - eps, "avatar not graded", "\(tag) chest \(entry.label)")
                    f.check(fit.waistEase >= prev.waistEase - eps, "avatar not graded", "\(tag) waist \(entry.label)")
                    f.check(fit.lengthDelta + fit.hemOffset >= prev.lengthDelta + prev.hemOffset - eps, "avatar not graded",
                            "\(tag) length \(entry.label)")
                    if case .top(true) = fit.kind {
                        f.check(fit.sleeveDelta >= prev.sleeveDelta - eps, "avatar not graded", "\(tag) sleeve \(entry.label)")
                    }
                    f.check(fit.shoulderDelta >= prev.shoulderDelta - eps, "avatar not graded", "\(tag) shoulder \(entry.label)")
                }
            }
            previous = fit
            // The avatar's verdicts are the chart's.
            for r in size.regions where r.verdict != .insufficientData {
                switch r.region {
                case .sleeve:
                    let long = r.verdict == .long, short = r.verdict == .short
                    let shown = fit.shownSleeve
                    f.check(!long || shown.delta >= shown.threshold, "avatar disagrees with chart", "\(tag) \(entry.label) sleeve chart long, avatar \(shown.delta)")
                    f.check(!short || shown.delta <= -shown.threshold, "avatar disagrees with chart", "\(tag) \(entry.label) sleeve chart short")
                    f.check(long || short || abs(shown.delta) < shown.threshold, "avatar disagrees with chart", "\(tag) \(entry.label) sleeve chart ideal, avatar \(shown.delta)")
                case .bodyLength, .inseam:
                    let shown = fit.shownLength
                    let long = r.verdict == .long, short = r.verdict == .short
                    f.check(!long || shown.delta >= shown.threshold, "avatar disagrees with chart", "\(tag) \(entry.label) length chart long")
                    f.check(!short || shown.delta <= -shown.threshold, "avatar disagrees with chart", "\(tag) \(entry.label) length chart short")
                case .chest, .waist, .hip, .thigh:
                    let zone: FitZone = switch r.region {
                    case .chest: .chest
                    case .waist: .waist
                    case .hip: bottom ? .hip : .abdomen
                    default: .thigh
                    }
                    if r.region == .hip && !bottom && p.spec.category != .dress { break }
                    if r.region == .hip && p.spec.category == .dress { break }
                    let want: FitTone = switch r.verdict {
                    case .tight, .slightlyTight: .tight
                    case .loose, .slightlyLoose: .loose
                    default: .fits
                    }
                    f.check(fit.judged.zones[zone] == want, "avatar disagrees with chart", "\(tag) \(entry.label) \(r.region) \(r.verdict)")
                default: break
                }
            }
            // A loose seat means loose legs.
            if fit.kind == .trousers, let seat = size.region(.hip), seat.verdict == .loose,
               size.regions.first(where: { $0.region == .thigh && $0.verdict != .insufficientData }) == nil {
                f.check(fit.judged.zones[.thigh] == .loose && fit.judged.zones[.knee] == .loose, "loose top, fitted below",
                        "\(tag) \(entry.label) seat loose, legs \(String(describing: fit.judged.zones[.thigh]))")
            }
        }

        // 3. The recommendation: not tight at the critical girth while a bigger size fits
        //    there; not loose while a smaller one does; the cut note agrees.
        let anyFits = analysis.sizes.contains { fitsAtCritical($0, crit) }
        stats.add(s, "a size fits at the \(bottom ? "waist" : "chest")", anyFits)
        if let best = analysis.recommendedSize, let bi = analysis.sizes.firstIndex(where: { $0.label == best.label }) {
            if let r = best.region(crit), r.verdict == .tight {
                let biggerFits = analysis.sizes[(bi + 1)...].contains { size in
                    fitsAtCritical(size, crit) && !size.regions.contains { $0.verdict == .tight }
                }
                f.check(!biggerFits, "recommends a tight size", "\(tag) \(best.label) \(crit) tight | " + Self.describe(analysis))
            }
            if let r = best.region(crit), r.verdict == .loose {
                let smallerFits = analysis.sizes[..<bi].contains { size in
                    fitsAtCritical(size, crit) && !size.regions.contains { $0.verdict == .tight || $0.verdict == .slightlyTight }
                }
                f.check(!smallerFits, "recommends a loose size", "\(tag) \(best.label) \(crit) loose | " + Self.describe(analysis))
            }
            if let note = CutGuide.note(for: p.spec, body: body, analysis: analysis) {
                f.check(note.size == best.label, "cut note size differs", "\(tag) note \(note.size ?? "-") vs \(best.label)")
                if let subtler = note.subtlerSize, let si = p.spec.sizes.firstIndex(where: { $0.label == subtler }) {
                    f.check(si < bi, "cut note subtler size not smaller", "\(tag) \(subtler)")
                }
                if let alt = note.alternativeChestCm, let chest = body[.chest]?.cm {
                    f.check(alt.lowerBound > chest, "alternative chest under body", "\(tag) \(alt)")
                }
            }
            // 4. Honest: never sure of a size that is tight, or loose, where it matters.
            if case let .size(_, confidence) = analysis.recommendation, let r = best.region(crit) {
                f.check(!(confidence == .high && (r.verdict == .tight || r.verdict == .loose)), "confident in a misfit",
                        "\(tag) \(best.label) \(crit) \(r.verdict) | " + Self.describe(analysis))
            }
            // Near the body on a body chart, when the body is inside the chart.
            if p.spec.chartKind == .body, let entry = p.spec.sizes.first(where: { $0.label == best.label }) {
                let dim: (GarmentDimension, BodyDimension) = bottom ? (.waist, .waist) : (.chest, .chest)
                if let g = entry.values[dim.0]?.cm, let b = body[dim.1]?.cm {
                    let span = p.spec.sizes.compactMap { $0.values[dim.0]?.cm }
                    let inRange = (span.min()! - 6...span.max()! + 6).contains(b)
                    f.check(!inRange || abs(g - b) <= 10, "recommended size far from body", "\(tag) \(best.label): size \(g) body \(b) | " + Self.describe(analysis))
                }
            }
        }
        // A body no size fits is told so: the critical verdict of every size says it.
        if !anyFits, let best = analysis.recommendedSize, let r = best.region(crit) {
            f.check(r.verdict != .ideal, "misfit called ideal", "\(tag) \(best.label)")
        }
        if analysis.recommendedSize != nil {
            f.check((analysis.noSizeFits != nil) == !anyFits, "no-size-fits notice wrong",
                    "\(tag) notice \(String(describing: analysis.noSizeFits)), a size fits: \(anyFits)")
        }

        // 5. Like a fitting room: snugger never bigger, looser never smaller.
        let chosen = picks(analysis)
        if let mid = chosen.min() {
            let snug = picks(engine.analyze(body: body, garment: p.spec, preference: .snugger))
            let loose = picks(engine.analyze(body: body, garment: p.spec, preference: .looser))
            if let a = snug.min() { f.check(a <= chosen.max()!, "snugger gave a bigger size", "\(tag) \(a) vs \(chosen)") }
            if let b = loose.max() { f.check(b >= mid, "looser gave a smaller size", "\(tag) \(b) vs \(chosen)") }
        }
        // Stretch never asks for a bigger size.
        if p.spec.chartKind == .garment, p.spec.stretch != .high, let base = chosen.min() {
            var stretchy = p.spec
            stretchy.stretch = .high
            if let b = picks(engine.analyze(body: body, garment: stretchy)).min() {
                f.check(b <= chosen.max()!, "stretch gave a bigger size", "\(tag) \(b) vs \(base)")
            }
        }
        // A bigger body never gets a smaller size.
        if let base = chosen.min() {
            var bigger = body
            for d in [BodyDimension.chest, .waist, .hip, .thigh] {
                if let v = bigger[d] { bigger[d] = MeasuredValue(cm: v.cm + (d == .thigh ? 3 : 5), uncertaintyCm: v.uncertaintyCm, source: v.source) }
            }
            if let b = picks(engine.analyze(body: bigger, garment: p.spec)).max() {
                f.check(b >= base, "bigger body, smaller size", "\(tag) \(b) vs \(chosen)")
            }
        }

        // 6. Knowing less: the app from height and weight only, and from a (noisy) scan,
        //    against the tape. Picking the other of two near-equal sizes is no harm; a
        //    size that on the real body is clearly worse (tight or loose where it matters,
        //    or a full region off) is, and being sure of it is what costs trust.
        let truth = s.scanned ? engine.analyze(body: s.body(.tape), garment: p.spec) : analysis
        let tape = picks(truth)
        guard let tapeBest = tape.map({ truth.sizes[$0].penalty }).min() else { return }
        for mode in [Population.Mode.scan, .estimate] {
            let a = engine.analyze(body: s.body(mode), garment: p.spec)
            let got = picks(a)
            guard !got.isEmpty else { continue }
            stats.add(s, "\(mode): same size as the tape", !got.isDisjoint(with: tape))
            stats.add(s, "\(mode): within one size", got.contains { g in tape.contains { abs($0 - g) <= 1 } })
            let worse = got.allSatisfy { g in
                let real = truth.sizes[g]
                let misfit = real.region(crit).map { $0.verdict == .tight || $0.verdict == .loose } ?? false
                return (misfit && !(truth.noSizeFits != nil)) || real.penalty - tapeBest > 1
            }
            stats.add(s, "\(mode): clearly worse size", worse)
            if case let .size(_, c) = a.recommendation, c == .high {
                stats.add(s, "\(mode): sure and clearly worse", worse)
                if worse, stats.examples.count < 12 {
                    stats.examples.append("\(tag) \(mode) \(a.recommendation) vs tape \(tape.sorted()) | \(mode): " + describe(a)
                                          + " | tape: " + describe(truth))
                }
            }
        }
    }

    static func describe(_ a: FitAnalysis) -> String {
        a.sizes.map { s in
            "\(s.label) p=\(String(format: "%.2f", s.penalty)) " + s.regions.map { r in
                "\(r.region.rawValue):\(r.verdict.rawValue)\(r.easeCm.map { String(format: "(%.1f)", $0) } ?? "")"
            }.joined(separator: ",")
        }.joined(separator: " ; ")
    }

    /// Rates by group (BMI class, shape, source, sex), for the report.
    struct Stats {
        var groups: [String: [String: (yes: Int, n: Int)]] = [:]
        var totals: [String: (yes: Int, n: Int)] = [:]
        var examples: [String] = []
        mutating func add(_ s: Shopper, _ metric: String, _ yes: Bool) {
            for g in ["all", "\(s.sex.rawValue)", "BMI \(s.bmiClass.rawValue)", "\(s.sex.rawValue) \(s.shape)", s.origin.rawValue,
                      "age \(s.ageBand)", "\(s.sex.rawValue) \(s.heightBand)"] {
                var t = groups[metric, default: [:]][g] ?? (0, 0)
                t.n += 1
                if yes { t.yes += 1 }
                groups[metric, default: [:]][g] = t
            }
        }
        mutating func count(_ metric: String, _ yes: Bool) {
            var t = totals[metric] ?? (0, 0)
            t.n += 1
            if yes { t.yes += 1 }
            totals[metric] = t
        }
        func rate(_ metric: String, _ group: String = "all") -> Double {
            guard let t = groups[metric]?[group], t.n > 0 else { return .nan }
            return Double(t.yes) / Double(t.n)
        }
        var report: String {
            groups.keys.sorted().map { metric in
                metric + "\n" + groups[metric]!.keys.sorted().map { g in
                    let t = groups[metric]![g]!
                    return "  \(g): \(String(format: "%.1f", 100 * Double(t.yes) / Double(max(1, t.n))))% of \(t.n)"
                }.joined(separator: "\n")
            }.joined(separator: "\n")
        }
    }

    @Test func fourHundredShoppers() throws {
        let shoppers = Population.shared
        try #require(shoppers.count == 400)
        var rng = RNG(state: 42)
        var findings = Findings()
        var stats = Stats()
        var garments = 0
        var kinds: [String: Int] = [:]
        for s in shoppers {
            for p in Self.products(for: s, rng: &rng) {
                garments += 1
                kinds["\(p.spec.category) / \(p.store)", default: 0] += 1
                Self.audit(s, p, into: &findings, stats: &stats)
            }
        }
        let report = "\(shoppers.count) shoppers, \(garments) garments, \(findings.checks) checks, \(findings.total) findings\n"
            + Population.describe(shoppers) + "\n"
            + kinds.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "\n"
            + findings.summary + "\n\n" + stats.report + "\n\nsure and clearly worse, examples:\n" + stats.examples.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["AUDIT_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(garments > 3800)
        #expect(Set(kinds.keys.map { $0.split(separator: "/")[0] }).count == GarmentCategory.allCases.count)
        #expect(findings.total == 0, "\(findings.summary)")
        // Working from height and weight alone, or from a scan, it is seldom sure of a
        // size clearly worse than the tape's: 1 in 20 at most (it says "between" or
        // lowers its confidence instead).
        for metric in ["scan: sure and clearly worse", "estimate: sure and clearly worse"] {
            let r = stats.rate(metric)
            #expect(r.isNaN || r <= 0.05, "\(metric): \(r)")
        }
        #expect(stats.rate("scan: within one size") >= 0.95)
    }

    /// Draped: half the shoppers, one garment each (every kind in turn), in the
    /// recommended size and two sizes up.
    @Test func drapedSample() throws {
        let shoppers = Population.shared
        try #require(shoppers.count == 400)
        var rng = RNG(state: 7)
        var findings = Findings()
        var drapes = 0
        var kinds: [GarmentCategory: Int] = [:]
        for s in shoppers where s.id % 2 == 0 {
            let products = Self.products(for: s, rng: &rng)
            // Cycle through the kinds so each is draped on many bodies.
            let wanted = GarmentCategory.allCases[(s.id / 2) % GarmentCategory.allCases.count]
            let p = products.first { $0.spec.category == wanted } ?? products[Int(rng.next() % UInt64(products.count))]
            let body = s.body(s.scanned ? .scan : .tape)
            let analysis = FitEngine().analyze(body: body, garment: p.spec)
            guard let bi = Self.picks(analysis).min() else { continue }
            kinds[p.spec.category, default: 0] += 1
            let m = s.measurements
            let model = BodyModel.make(m)
            for i in Set([bi, min(p.spec.sizes.count - 1, bi + 2)]).sorted() {
                let entry = p.spec.sizes[i], regions = analysis.sizes[i].regions
                let tag = "#\(s.id) \(s.sex) BMI \(Int(s.bmi)) \(p.name) [\(p.store)] \(entry.label)"
                let fit = AvatarFitMapper.fit(spec: p.spec, size: entry, body: body, regions: regions)
                let layer = Avatar(m, garment: fit, detail: .preview).layers[0]
                drapes += 1
                let mesh = layer.mesh
                func share(_ tone: FitTone, _ band: ClosedRange<Float>) -> Double {
                    let ids = mesh.positions.indices.filter { band.contains(mesh.positions[$0].y) }
                    return Double(ids.filter { mesh.tones[$0] == tone }.count) / Double(max(1, ids.count))
                }
                func verdict(_ r: FitRegion) -> FitVerdict? { regions.first { $0.region == r }?.verdict }
                // The cloth lies on the body, not in it.
                let sunk = mesh.positions.filter { model.distance($0) < -0.006 }.count
                findings.check(Double(sunk) / Double(max(1, mesh.positions.count)) < 0.02, "cloth inside the body",
                               "\(tag) \(sunk) of \(mesh.positions.count)")
                // Long garments reach past the seat round both legs.
                if p.spec.category == .dress || p.spec.category == .coat || p.spec.category == .skirt {
                    let lowest = mesh.positions.map(\.y).min() ?? 0
                    findings.check(lowest < model.crotchY - 0.05, "long garment too short", "\(tag) hem at \(lowest)")
                }
                // The zone report says what the chart says, zone by zone.
                for (zone, want) in fit.judged.tensions {
                    guard let got = layer.fitReport[zone]?.tension else { continue }
                    findings.check(got == want || (got == .veryTight && want >= .tight), "zone report disagrees",
                                   "\(tag) \(zone): \(got) vs \(want)")
                }
                if case .trousers = fit.kind {
                    let thigh = (model.kneeY + 0.08 * model.h)...(model.crotchY - 0.03 * model.h)
                    if fit.judged.zones[.thigh] == .loose {
                        findings.check(share(.loose, thigh) > 0.5, "draped legs not loose", "\(tag) \(share(.loose, thigh))")
                    }
                    if fit.judged.zones[.thigh] == .fits, fit.judged.zones[.hip] == .fits {
                        findings.check(share(.loose, thigh) < 0.3, "draped legs loose though they fit", "\(tag) \(share(.loose, thigh))")
                    }
                    if verdict(.inseam) == .long {
                        findings.check(layer.placements.contains { $0.edge == .legs && !$0.usual }, "placement says usual",
                                       "\(tag) legs")
                    }
                } else if case .top(true) = fit.kind {
                    if verdict(.sleeve) == .long {
                        findings.check(layer.placements.contains { $0.edge == .sleeve && !$0.usual && $0.offsetCm > 0 },
                                       "placement says usual", "\(tag) sleeve")
                    }
                    if verdict(.sleeve) == .ideal {
                        findings.check(layer.placements.contains { $0.edge == .sleeve && $0.usual }, "placement says unusual",
                                       "\(tag) sleeve \(layer.placements)")
                    }
                }
            }
        }
        let report = "\(drapes) drapes, \(findings.checks) checks, \(findings.total) findings\n"
            + kinds.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ") + "\n" + findings.summary
        print(report)
        if let path = ProcessInfo.processInfo.environment["AUDIT_REPORT"] {
            try report.write(toFile: path + ".draped.txt", atomically: true, encoding: .utf8)
        }
        #expect(kinds.count == GarmentCategory.allCases.count)
        #expect(findings.total == 0, "\(findings.summary)")
    }
}
