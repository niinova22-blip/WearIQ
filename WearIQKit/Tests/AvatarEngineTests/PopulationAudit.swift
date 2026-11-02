import FitEngine
import Foundation
import ProductMeasurementParser
import Testing
@testable import AvatarEngine
import WearIQCore

/// A hundred shoppers, 50 men and 50 women, with real bodies from the ANSUR II survey
/// (tape-measured; public domain, https://www.openlab.psu.edu/ansur2/), each liking
/// different cuts and buying from different kinds of store: one with a garment
/// (flat-measured) chart, one with a body chart, one with no chart where only the
/// model's size and height are known. Every garment is checked in every size for
/// contradictions between what the size chart says, what the cut note says and what
/// the avatar shows:
///
/// - a bigger size is never tighter, nor shorter, anywhere;
/// - the avatar grades what the chart leaves out with the size (a 2XL's sleeves are longer
///   than an M's, its thighs roomier) and its verdicts are the chart's;
/// - the recommended size is one whose critical girth isn't called tight while a bigger
///   size fits, and the cut note recommends the same size;
/// - draped, a size the chart calls loose at the seat is loose down the leg, a top
///   called long in the sleeves shows its cuffs past the wrist.
///
/// `AUDIT_REPORT=path` writes every finding out.
@Suite struct PopulationAudit {
    struct Shopper {
        var id: Int
        var sex: BodySex
        var age: Int
        var body: BodyProfile
        var m: Avatar.Measurements
        /// Cuts this shopper likes.
        var tops: FitStyle
        var legs: LegCut?
    }

    struct Product {
        var name: String
        var store: String
        var spec: GarmentSpec
    }

    /// SplitMix64: the same shoppers and products on every run.
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

    // MARK: Shoppers

    static func ansur(_ file: String, _ sex: BodySex) -> [[String: Double]] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../BodyMeasurementEngineTests/Data/\(file)")
        guard let text = try? String(contentsOf: url, encoding: .isoLatin1) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",").map({ $0.lowercased() }) else { return [] }
        return lines.dropFirst().map { line in
            var row: [String: Double] = [:]
            for (name, cell) in zip(header, line.split(separator: ",", omittingEmptySubsequences: false)) { row[name] = Double(cell) }
            return row
        }
    }

    static func shoppers() -> [Shopper] {
        var rng = RNG(state: 2026_11_02)
        let men = ansur("ANSUR_II_MALE_Public.csv", .male), women = ansur("ANSUR_II_FEMALE_Public.csv", .female)
        guard !men.isEmpty, !women.isEmpty else { return [] }
        var out: [Shopper] = []
        for i in 0..<100 {
            let sex: BodySex = i % 2 == 0 ? .male : .female
            let pool = sex == .male ? men : women
            let r = pool[Int(rng.next() % UInt64(pool.count))]
            func cm(_ k: String) -> Double { (r[k] ?? 0) / 10 }
            // Half tape-measured, half scanned (wider uncertainty, shoulders bone to bone).
            let scanned = rng.unit() < 0.5
            func v(_ x: Double, _ tape: Double, _ scan: Double) -> MeasuredValue {
                MeasuredValue(cm: x, uncertaintyCm: scanned ? scan : tape, source: scanned ? .scan : .manual)
            }
            let height = cm("stature")
            let values: [BodyDimension: MeasuredValue] = [
                .height: MeasuredValue(cm: height, uncertaintyCm: 0.5, source: .userProvided),
                .chest: v(cm("chestcircumference"), 1, 2.5),
                .waist: v(cm("waistcircumference"), 1, 2.5),
                .hip: v(cm("buttockcircumference"), 1, 2.5),
                .thigh: v(cm("thighcircumference"), 1, 2.5),
                .shoulderWidth: v(cm("biacromialbreadth"), 1, 1.5),
                .armLength: v(cm("acromionradialelength") + cm("radialestylionlength"), 1, 2),
                .torsoLength: v(cm("cervicaleheight") - cm("waistheightomphalion"), 1.5, 2.5),
                .inseam: v(cm("crotchheight"), 1, 2),
            ]
            var body = BodyProfile(values: values)
            body.sex = sex
            body.weightKg = (r["weightkg"] ?? 0) / 10
            guard let m0 = Avatar.Measurements(body) else { continue }
            var m = m0
            m.sex = sex
            let tops: FitStyle = rng.pick([.slim, .regular, .regular, .relaxed, .oversized])
            let legs: LegCut? = rng.pick(sex == .female ? [.skinny, .straight, .wide, .flare, .tapered, nil]
                                                        : [.skinny, .slim, .straight, .tapered, .wide, nil])
            out.append(Shopper(id: i, sex: sex, age: Int(r["age"] ?? 30), body: body, m: m, tops: tops, legs: legs))
        }
        return out
    }

    // MARK: Products

    static func letterLabels(_ sex: BodySex) -> [String] {
        sex == .male ? ["S", "M", "L", "XL", "2XL", "3XL"] : ["XS", "S", "M", "L", "XL", "2XL"]
    }

    static func mv(_ x: Double, _ u: Double = 0.5) -> MeasuredValue { MeasuredValue(cm: x, uncertaintyCm: u, source: .manual) }

    /// A store's flat-measured chart for a top, graded as patterns are.
    static func garmentTop(_ category: GarmentCategory, _ fit: FitStyle, _ sex: BodySex, rng: inout RNG) -> GarmentSpec {
        let labels = letterLabels(sex)
        let mIndex = sex == .male ? 1 : 2
        // An M's body: men chest 100, women bust 90.
        let body = sex == .male ? 100.0 : 90
        let ease: Double = switch fit {
        case .slim: 7
        case .regular: 13
        case .relaxed: 19
        case .oversized: 30
        }
        let step = sex == .male ? rng.range(6...8) : rng.range(4...6)
        let brand = rng.range(-3...3)
        let length: Double = (category == .tshirt ? (sex == .male ? 71 : 62) : (sex == .male ? 74 : 64)) + (fit == .oversized ? 3 : 0)
        let sleeve: Double = sex == .male ? 63 : 59
        let shoulder: Double = (sex == .male ? 46 : 39) + (fit == .oversized ? 8 : fit == .relaxed ? 3 : fit == .slim ? -1 : 0)
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
            return SizeEntry(label: label, values: v)
        }
        return GarmentSpec(category: category, fitStyle: fit, chartKind: .garment, sizes: sizes)
    }

    /// A store's flat-measured chart for trousers (waist sizes for men, EU for women).
    static func garmentTrousers(_ cut: LegCut?, _ sex: BodySex, rng: inout RNG) -> GarmentSpec {
        let labels: [String] = sex == .male ? ["28", "30", "32", "34", "36", "38", "40"] : ["34", "36", "38", "40", "42", "44"]
        let fit = cut?.impliedFit ?? .regular
        let (hipEase, thighRatio): (Double, Double) = switch cut {
        case .skinny?: (2, 0.53)
        case .slim?, .flare?: (5, 0.57)
        case .straight?: (8, 0.61)
        case .tapered?: (11, 0.62)
        case .wide?: (16, 0.68)
        case nil: (7, 0.6)
        }
        let stretch: FabricStretch = cut == .skinny ? .medium : .low
        let sizes = labels.map { label -> SizeEntry in
            let n = Double(label)!
            let waist = sex == .male ? n * 2.54 + 1 : 66 + (n - 36) * 2
            let bodyHip = sex == .male ? waist + 17 : waist + 26
            let hip = bodyHip + hipEase
            let inseam = sex == .male ? 81.0 : 78
            return SizeEntry(label: label, values: [
                .waist: mv(waist + rng.range(-1...1)), .hip: mv(hip), .thigh: mv(hip * thighRatio), .inseam: mv(inseam),
            ])
        }
        return GarmentSpec(category: .pants, fitStyle: fit, stretch: stretch, chartKind: .garment, sizes: sizes, legCut: cut)
    }

    /// A store's body chart (the body each size suits), shifted a little by brand.
    static func bodyChart(_ category: GarmentCategory, _ fit: FitStyle, _ sex: BodySex, cut: LegCut?, rng: inout RNG) -> GarmentSpec? {
        let labels = category == .pants && sex == .male ? ["28", "30", "32", "34", "36", "38", "40"] : letterLabels(sex)
        guard var chart = StandardSizeCharts.chart(for: labels, category: category, audience: sex == .male ? .men : .women) else { return nil }
        let shift = rng.range(-3...3)
        for i in chart.sizes.indices {
            for (d, v) in chart.sizes[i].values {
                chart.sizes[i].values[d] = MeasuredValue(cm: v.cm + shift, uncertaintyCm: 2, source: .manual)
            }
        }
        return GarmentSpec(category: category, fitStyle: fit, chartKind: .body, sizes: chart.sizes,
                           legCut: category.isBottom ? cut : nil)
    }

    /// No chart: the standard one, anchored to the model's size and height.
    static func modelChart(_ category: GarmentCategory, _ fit: FitStyle, _ sex: BodySex, cut: LegCut?, rng: inout RNG) -> GarmentSpec? {
        let labels = category == .pants && sex == .male ? ["28", "30", "32", "34", "36", "38", "40"] : letterLabels(sex)
        let worn = category == .pants && sex == .male ? "32" : sex == .male ? "M" : "S"
        let height = sex == .male ? rng.range(182...190) : rng.range(172...179)
        let anchor = ModelFit(size: worn, heightCm: height, chestCm: rng.unit() < 0.5 ? (sex == .male ? 98 : 84) : nil)
        guard let chart = StandardSizeCharts.chart(for: labels, category: category, audience: sex == .male ? .men : .women,
                                                   anchor: anchor) else { return nil }
        return GarmentSpec(category: category, fitStyle: fit, chartKind: chart.kind ?? .body, sizes: chart.sizes,
                           legCut: category.isBottom ? cut : nil)
    }

    static func products(for s: Shopper, rng: inout RNG) -> [Product] {
        var out: [Product] = []
        let topKinds: [GarmentCategory] = s.sex == .male ? [.tshirt, .shirt, .sweater, .jacket] : [.tshirt, .shirt, .sweater, .dress]
        for _ in 0..<4 {
            let c = rng.pick(topKinds)
            let fit = rng.unit() < 0.7 ? s.tops : rng.pick([FitStyle.slim, .regular, .relaxed, .oversized])
            switch rng.next() % 3 {
            case 0:
                out.append(Product(name: "\(fit) \(c)", store: "garment chart", spec: garmentTop(c == .dress ? .shirt : c, fit, s.sex, rng: &rng)))
            case 1:
                if let spec = bodyChart(c, fit, s.sex, cut: nil, rng: &rng) { out.append(Product(name: "\(fit) \(c)", store: "body chart", spec: spec)) }
            default:
                if let spec = modelChart(c, fit, s.sex, cut: nil, rng: &rng) { out.append(Product(name: "\(fit) \(c)", store: "model only", spec: spec)) }
            }
        }
        for _ in 0..<3 {
            let cut = rng.unit() < 0.7 ? s.legs : rng.pick([LegCut.skinny, .slim, .straight, .wide, .flare, .tapered])
            let fit = cut?.impliedFit ?? .regular
            switch rng.next() % 3 {
            case 0: out.append(Product(name: "\(cut?.rawValue ?? "regular") trousers", store: "garment chart", spec: garmentTrousers(cut, s.sex, rng: &rng)))
            case 1:
                if let spec = bodyChart(.pants, fit, s.sex, cut: cut, rng: &rng) {
                    out.append(Product(name: "\(cut?.rawValue ?? "regular") trousers", store: "body chart", spec: spec))
                }
            default:
                if let spec = modelChart(.pants, fit, s.sex, cut: cut, rng: &rng) {
                    out.append(Product(name: "\(cut?.rawValue ?? "regular") trousers", store: "model only", spec: spec))
                }
            }
        }
        if s.sex == .female, let skirt = bodyChart(.skirt, rng.pick([.slim, .regular, .relaxed]), .female, cut: nil, rng: &rng) {
            out.append(Product(name: "skirt", store: "body chart", spec: skirt))
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

    static func audit(_ s: Shopper, _ p: Product, into f: inout Findings) {
        let analysis = FitEngine().analyze(body: s.body, garment: p.spec)
        let tag = "#\(s.id) \(s.sex) \(p.name) [\(p.store)]"
        let bottom = p.spec.category.isBottom
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
            let fit = AvatarFitMapper.fit(spec: p.spec, size: entry, body: s.body, regions: size.regions)
            if let prev = previous {
                let eps = 0.01
                if bottom {
                    f.check(fit.waistEase >= prev.waistEase - eps, "avatar not graded", "\(tag) waist \(entry.label)")
                    f.check(fit.hipEase >= prev.hipEase - eps, "avatar not graded", "\(tag) hip \(entry.label)")
                    f.check(fit.thighEase >= prev.thighEase - eps, "avatar not graded", "\(tag) thigh \(entry.label)")
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
                    if r.region == .hip && !bottom { break }
                    let want: FitTone = switch r.verdict {
                    case .tight, .slightlyTight: .tight
                    case .loose, .slightlyLoose: .loose
                    default: .fits
                    }
                    f.check(fit.judged.zones[zone] == want, "avatar disagrees with chart", "\(tag) \(entry.label) \(r.region) \(r.verdict)")
                default: break
                }
            }
            // A loose seat means loose legs; a loose chest loose sleeves.
            if bottom, let seat = size.regions.first(where: { $0.region == .hip }), seat.verdict == .loose,
               size.regions.first(where: { $0.region == .thigh && $0.verdict != .insufficientData }) == nil {
                f.check(fit.judged.zones[.thigh] == .loose && fit.judged.zones[.knee] == .loose, "loose top, fitted below",
                        "\(tag) \(entry.label) seat loose, legs \(String(describing: fit.judged.zones[.thigh]))")
            }
        }
        // 3. The recommendation: not tight at a critical girth while a bigger size fits it;
        //    the cut note recommends the same size.
        if let best = analysis.recommendedSize, let bi = analysis.sizes.firstIndex(where: { $0.label == best.label }) {
            let critical: FitRegion = bottom ? .waist : .chest
            if let r = best.regions.first(where: { $0.region == critical }), r.verdict == .tight {
                // A bigger size that fits there and is tight nowhere.
                let biggerFits = analysis.sizes[(bi + 1)...].contains { size in
                    (size.regions.first { $0.region == critical }.map { [.ideal, .slightlyLoose, .slightlyTight].contains($0.verdict) } ?? false)
                        && !size.regions.contains { $0.verdict == .tight }
                }
                f.check(!biggerFits, "recommends a tight size", "\(tag) \(best.label) \(critical) tight | " + Self.describe(analysis, s.body))
            }
            if let r = best.regions.first(where: { $0.region == critical }), r.verdict == .loose {
                // A smaller size that fits there and is tight nowhere.
                let smallerFits = analysis.sizes[..<bi].contains { size in
                    (size.regions.first { $0.region == critical }.map { [.ideal, .slightlyLoose, .slightlyTight].contains($0.verdict) } ?? false)
                        && !size.regions.contains { $0.verdict == .tight || $0.verdict == .slightlyTight }
                }
                f.check(!smallerFits, "recommends a loose size", "\(tag) \(best.label) \(critical) loose | " + Self.describe(analysis, s.body))
            }
            if let note = CutGuide.note(for: p.spec, body: s.body, analysis: analysis) {
                f.check(note.size == best.label, "cut note size differs", "\(tag) note \(note.size ?? "-") vs \(best.label)")
                if let subtler = note.subtlerSize, let si = p.spec.sizes.firstIndex(where: { $0.label == subtler }) {
                    f.check(si < bi, "cut note subtler size not smaller", "\(tag) \(subtler)")
                }
                if let alt = note.alternativeChestCm, let chest = s.body[.chest]?.cm {
                    f.check(alt.lowerBound > chest, "alternative chest under body", "\(tag) \(alt)")
                }
            }
        }
        // 4. The recommended size is a sane one for this body: within the usual sizes
        //    for its chest or waist on a body chart.
        if p.spec.chartKind == .body, let best = analysis.recommendedSize,
           let entry = p.spec.sizes.first(where: { $0.label == best.label }) {
            let dim: (GarmentDimension, BodyDimension) = bottom ? (.waist, .waist) : (.chest, .chest)
            if let g = entry.values[dim.0]?.cm, let b = s.body[dim.1]?.cm {
                let span = p.spec.sizes.compactMap { $0.values[dim.0]?.cm }
                let inRange = (span.min()! - 6...span.max()! + 6).contains(b)
                f.check(!inRange || abs(g - b) <= 10, "recommended size far from body", "\(tag) \(best.label): size \(g) body \(b)")
            }
        }
    }

    static func describe(_ a: FitAnalysis, _ body: BodyProfile) -> String {
        a.sizes.map { s in
            "\(s.label) p=\(String(format: "%.2f", s.penalty)) " + s.regions.map { r in
                "\(r.region.rawValue):\(r.verdict.rawValue)\(r.easeCm.map { String(format: "(%.1f)", $0) } ?? "")"
            }.joined(separator: ",")
        }.joined(separator: " ; ")
    }

    @Test func hundredShoppers() throws {
        let shoppers = Self.shoppers()
        try #require(shoppers.count == 100)
        #expect(shoppers.filter { $0.sex == .male }.count == 50)
        var rng = RNG(state: 42)
        var findings = Findings()
        var garments = 0
        for s in shoppers {
            for p in Self.products(for: s, rng: &rng) {
                garments += 1
                Self.audit(s, p, into: &findings)
            }
        }
        let report = "\(shoppers.count) shoppers, \(garments) garments, \(findings.checks) checks, \(findings.total) findings\n"
            + findings.summary
        print(report)
        if let path = ProcessInfo.processInfo.environment["AUDIT_REPORT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #expect(findings.total == 0, "\(findings.summary)")
    }
    /// Draped: a sample of shoppers and garments, in the recommended size and two sizes up.
    @Test func drapedSample() throws {
        let shoppers = Self.shoppers()
        try #require(shoppers.count == 100)
        var rng = RNG(state: 7)
        var findings = Findings()
        var drapes = 0
        for s in shoppers where s.id % 5 == 0 {
            let products = Self.products(for: s, rng: &rng)
            let p = products[Int(rng.next() % UInt64(products.count))]
            let analysis = FitEngine().analyze(body: s.body, garment: p.spec)
            guard let best = analysis.recommendedSize,
                  let bi = p.spec.sizes.firstIndex(where: { $0.label == best.label }) else { continue }
            let model = BodyModel.make(s.m)
            for i in Set([bi, min(p.spec.sizes.count - 1, bi + 2)]).sorted() {
                let entry = p.spec.sizes[i], regions = analysis.sizes[i].regions
                let tag = "#\(s.id) \(s.sex) \(p.name) [\(p.store)] \(entry.label)"
                let fit = AvatarFitMapper.fit(spec: p.spec, size: entry, body: s.body, regions: regions)
                let layer = Avatar(s.m, garment: fit, detail: .preview).layers[0]
                drapes += 1
                let mesh = layer.mesh
                func share(_ tone: FitTone, _ band: ClosedRange<Float>) -> Double {
                    let ids = mesh.positions.indices.filter { band.contains(mesh.positions[$0].y) }
                    return Double(ids.filter { mesh.tones[$0] == tone }.count) / Double(max(1, ids.count))
                }
                func verdict(_ r: FitRegion) -> FitVerdict? { regions.first { $0.region == r }?.verdict }
                // The zone report says what the chart says, zone by zone.
                for (zone, want) in fit.judged.tensions {
                    guard let got = layer.fitReport[zone]?.tension else { continue }
                    findings.check(got == want || (got == .veryTight && want >= .tight), "zone report disagrees",
                                   "\(tag) \(zone): \(got) vs \(want)")
                }
                if fit.kind.isBottom, case .trousers = fit.kind {
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
        let report = "\(drapes) drapes, \(findings.checks) checks, \(findings.total) findings\n" + findings.summary
        print(report)
        #expect(findings.total == 0, "\(findings.summary)")
    }
}
