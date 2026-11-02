import AvatarEngine
import FitEngine
import ProductMeasurementParser
import SceneKit
import SwiftData
import SwiftUI
import WearIQCore

extension Avatar.Landmark.Kind {
    var title: String {
        switch self {
        case .neck: String(localized: "Neck")
        case .shoulder: String(localized: "Shoulder point")
        case .chest: String(localized: "Chest")
        case .elbow: String(localized: "Elbow")
        case .waist: String(localized: "Waist")
        case .wrist: String(localized: "Wrist")
        case .hip: String(localized: "Hip")
        case .crotch: String(localized: "Crotch")
        case .thigh: String(localized: "Thigh")
        case .knee: String(localized: "Kneecap")
        case .ankle: String(localized: "Ankle")
        }
    }
}

/// Turns a garment's size chart into how it sits on the avatar: ease (garment minus
/// body girth) and how much longer or shorter than the body each length is. Garment
/// charts give the ease directly; body charts describe the body a size suits, so the
/// garment is taken as that body plus the usual ease for the fit (see EaseTable).
enum AvatarFitMapper {
    /// Thigh ease of a leg cut's usual size, cm, for charts without a thigh.
    static func typicalThigh(_ cut: LegCut?) -> Double? {
        switch cut {
        case .skinny?: 2
        case .slim?, .flare?: 5
        case .straight?: 9
        case .tapered?: 12
        case .wide?: 18
        case nil: nil
        }
    }

    /// With `regions` (the size-chart verdicts for this size), the avatar's colours,
    /// lines and labels say what those verdicts say.
    static func fit(spec: GarmentSpec, size: SizeEntry, body: BodyProfile, regions: [RegionFit] = [],
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
        func ease(_ g: GarmentDimension, _ b: BodyDimension, typical: Double) -> Double {
            guard let d = diff(g, b) else { return typical }
            return spec.chartKind == .garment ? d : typical + d
        }
        let style = spec.fitStyle
        // A length the chart gives per size; one that is the same for every size was
        // filled in from the model's photo (or the chart doesn't grade it) and says
        // nothing about this size.
        func graded(_ g: GarmentDimension) -> Double? {
            guard let v = size.values[g]?.cm else { return nil }
            let all = spec.sizes.compactMap { $0.values[g]?.cm }
            return spec.sizes.count > 1 && all.count == spec.sizes.count && Set(all.map { ($0 * 2).rounded() }).count == 1 ? nil : v
        }
        // Sizes this one is from a regular fit on this body (+ bigger): lengths grow
        // with the size as its girths do, about 1.5 cm in length and 1 cm in sleeve for
        // every 5 cm of chest (4 cm of waist), as patterns are graded.
        var steps = 0.0
        // The design length the name says, cm from the kind's usual one.
        let words = SizeChartParser.foldForMatching(name ?? "")
        func hint(_ table: [(String, Double)]) -> Double { table.first { words.contains($0.0) }?.1 ?? 0 }
        if spec.category == .skirt {
            fit.waistEase = ease(.waist, .waist, typical: 1.5)
            fit.hipEase = ease(.hip, .hip, typical: [FitStyle.slim: 5, .regular: 8, .relaxed: 16, .oversized: 30][style] ?? 8)
            steps = (fit.waistEase - 1.5) / 4
            // Waistband to hem; a regular skirt ends just above the knee.
            if let length = graded(.bodyLength) {
                fit.hemOffset = length - 0.245 * height
            } else {
                fit.lengthFromChart = false
                fit.hemOffset = hint([("mini", -0.065), ("midi", 0.15), ("maxi", 0.25), ("maksi", 0.25), ("uzun", 0.2)]) * height
                    + steps * 1.0
            }
        } else if spec.category == .shorts {
            fit.waistEase = ease(.waist, .waist, typical: 1.5)
            fit.hipEase = ease(.hip, .hip, typical: [FitStyle.slim: 4, .regular: 8, .relaxed: 14, .oversized: 22][style] ?? 8)
            fit.thighEase = ease(.thigh, .thigh, typical: [FitStyle.slim: 6, .regular: 12, .relaxed: 20, .oversized: 30][style] ?? 12)
            // Legs end mid-thigh unless the chart gives the inseam ("bermuda" to the knee).
            fit.lengthFromChart = size.values[.inseam] != nil
            if let inseam = size.values[.inseam]?.cm, let body = body[.inseam]?.cm {
                fit.hemOffset = inseam - body
            } else {
                fit.hemOffset = -(words.contains("bermuda") ? 0.25 : 0.335) * height
            }
        } else if isTrousers {
            fit.waistEase = ease(.waist, .waist, typical: 1.5)
            fit.hipEase = ease(.hip, .hip, typical: [FitStyle.slim: 4, .regular: 7, .relaxed: 12, .oversized: 20][style] ?? 7)
            fit.thighEase = ease(.thigh, .thigh, typical: Self.typicalThigh(spec.legCut)
                ?? [FitStyle.slim: 5, .regular: 9, .relaxed: 15, .oversized: 24][style] ?? 9)
            fit.lengthDelta = diff(.inseam, .inseam) ?? diff(.outseam, .outseam) ?? 0
        } else {
            let over: Double = spec.category == .coat ? 6 : 0
            let chestTypical: Double = ([FitStyle.slim: 7, .regular: 12, .relaxed: 19, .oversized: 30][style] ?? 12) + over
            fit.chestEase = ease(.chest, .chest, typical: chestTypical)
            fit.waistEase = ease(.waist, .waist, typical: spec.category == .dress ? chestTypical - 4 : chestTypical + 3)
            fit.hipEase = spec.category == .dress ? ease(.hip, .hip, typical: chestTypical - 2) : fit.waistEase
            steps = (fit.chestEase - chestTypical) / 5
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
                    fit.hemOffset = named * height + steps * 1.5
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
                    fit.lengthDelta = steps * 1.5
                    fit.judged.length = nil
                }
            }
            if graded(.sleeveLength) != nil, let d = diff(.sleeveLength, .armLength) {
                fit.sleeveDelta = spec.chartKind == .garment ? d - 2.5 : d
            } else {
                fit.sleeveFromChart = false
                fit.sleeveDelta = steps * 1.0
                fit.judged.sleeve = nil
            }
            // The chart's shoulder runs over the back; a scanned one is bone to bone.
            let shoulder = body[.shoulderWidth].map(FitEngine.acrossBack)
            if let gv = size.values[.shoulderWidth]?.cm, let bv = shoulder?.cm {
                let d = gv - bv
                fit.shoulderDelta = spec.chartKind == .garment ? d : d + (style == .oversized ? 7 : 0)
            } else {
                // No shoulder on the chart: shoulders are graded with the chest, about 1.2 cm
                // for every 4–5 cm (ISO 8559 grading). So a size cut roomier than a regular
                // fit of this kind on this body has its seams that much further out, and a
                // smaller one further in (every size used to say "seams on your shoulders").
                let graded = (fit.chestEase - chestTypical) * 0.27
                fit.shoulderDelta = graded + (style == .oversized ? 7 : 0)
            }
        }
        return fit
    }

    /// The avatar's garment for a category: sleeves from the category, or for a dress from
    /// the chart (a sleeve over 30 cm is a long one).
    static func kind(_ spec: GarmentSpec, _ size: SizeEntry) -> Avatar.GarmentFit.Kind {
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
    static func judged(_ regions: [RegionFit], trousers: Bool) -> Avatar.GarmentFit.Judged {
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
        let covered: [(FitRegion, [FitZone])] = trousers
            ? [(.waist, [.waist]), (.hip, [.hip]), (.thigh, [.thigh])]
            : [(.chest, [.chest, .back]), (.waist, [.waist, .abdomen, .hip])]
        func tension(_ r: RegionFit) -> ZoneTension {
            switch r.verdict {
            case .tight: .tight
            case .slightlyTight: .slightlyTight
            case .loose, .slightlyLoose: .loose
            default: .comfortable
            }
        }
        for (region, zones) in covered {
            guard let r = by(region) else { continue }
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
    static func fabric(spec: GarmentSpec, material: String?) -> Fabric {
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
    static func bodyRange(_ body: BodyProfile, around m: Avatar.Measurements) -> (Avatar.Measurements?, Avatar.Measurements?) {
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

    /// Where each fit region's dot goes.
    static func anchor(for region: FitRegion, trousers: Bool) -> Avatar.Anchor {
        switch region {
        case .shoulder: .shoulder
        case .chest: .chest
        case .waist: .waist
        case .hip: .hip
        case .thigh: .thigh
        case .sleeve: .sleeveEnd
        case .bodyLength, .inseam, .outseam: .hem
        }
    }
}

/// "See it on my avatar": the chosen size draped on the user's own 3D body, on one
/// screen. The garment is coloured by how it sits (blue fits, yellow loose, red long,
/// purple tight, orange short), with glowing lines where its shoulder seams, cuffs and
/// hems fall and white dashes where they belong; labels say by how much. A second piece
/// can be worn with it, a top with trousers, from the garments analysed before. The
/// zone-by-zone simulation report and the size comparison are Premium.
struct AvatarFitView: View {
    let analysis: FitAnalysis
    let spec: GarmentSpec
    @State var sizeLabel: String
    /// The fabric composition from the product page, when known.
    var material: String?
    /// The product's name: "mini", "midi", "long" in it set a skirt's or coat's length
    /// when the chart has none.
    var productName: String?
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var saved: [SavedAnalysis]
    /// The gender chosen at setup, for profiles saved before they carried it.
    @AppStorage("bodySex") private var sexRaw = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container
    @State private var avatar: Avatar?
    @State private var revision = 0
    /// The frame of the dressing being shown, nil once it has settled.
    @State private var frame: Int?
    @StateObject private var labelModel = LandmarkLabels()
    /// Every size draped, on the body as measured and at the ends of its ranges.
    @State private var comparison: [SizeDrape]?
    @State private var comparing = false
    @State private var showPaywall = false
    /// The other piece worn with this one.
    @State private var companion: Companion?
    @State private var choosingCompanion = false
    /// The view last asked for with the buttons under the avatar.
    @State private var facing: Float?
    @State private var facingTurn = 0
    /// While a size or an outfit is being draped: the scene says so, so a wait of a few
    /// seconds doesn't look like a frozen screen.
    @State private var draping = true
    /// The size being put on, for the loading badge: this garment's or the other piece's,
    /// whichever changed (trousers in 33 aren't "size XS").
    @State private var drapingSize: String?
    /// What the last drape put on: this garment's size, and the other piece and its size.
    @State private var lastMain: String?
    @State private var lastCompanion: String?
    /// The scene's height and what the colour key and the controls cover of it, for
    /// framing the body in between.
    @State private var sceneHeight: CGFloat = 0
    @State private var legendBottom: CGFloat = 0
    @State private var controlsHeight: CGFloat = 0
    /// Pieces taken off the view to see the one under them (a skirt under a coat).
    @State private var hiddenLayers: Set<Int> = []

    /// A garment analysed earlier, worn together with this one.
    struct Companion: Equatable {
        var key: String
        var name: String
        var spec: GarmentSpec
        var analysis: FitAnalysis
        var material: String?
        var size: String

        static func == (a: Self, b: Self) -> Bool { a.key == b.key && a.size == b.size }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let body = profiles.first?.profile, Avatar.Measurements(body) != nil {
                    VStack(spacing: 0) {
                        ZStack {
                            if let avatar {
                                AvatarSceneView(avatar: avatar, revision: revision, frame: frame,
                                                labels: frame == nil && !draping ? labels(avatar) : [], labelModel: labelModel,
                                                facing: facing, facingTurn: facingTurn,
                                                viewHeight: sceneHeight, coveredTop: legendBottom, coveredBottom: controlsHeight,
                                                hidden: hiddenLayers)
                                LandmarkOverlay(model: labelModel)
                            }
                            VStack(spacing: 0) {
                                legend.allowsHitTesting(false)
                                layerToggles
                                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("avatarScene")).maxY } action: {
                                        legendBottom = $0
                                    }
                                Spacer(minLength: 0)
                                VStack(spacing: 0) {
                                    tailorCard.allowsHitTesting(false)
                                    viewButtons
                                    Label("Drag to turn", systemImage: "hand.draw")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.bottom, 6)
                                        .allowsHitTesting(false)
                                }
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlsHeight = $0 }
                            }
                            if draping || avatar == nil {
                                loadingBadge
                                    .transition(.opacity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: draping)
                        .coordinateSpace(.named("avatarScene"))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sceneHeight = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .background(RadialGradient(colors: [Color(white: 0.32), Color(white: 0.1)], center: .center,
                                                   startRadius: 20, endRadius: 520))
                        panel
                    }
                    .task(id: drapeKey) { await drape(body) }
                } else {
                    ContentUnavailableView("Scan or enter your measurements first", systemImage: "figure.stand")
                }
            }
            .background(Theme.screenBackground)
            .navigationTitle("On your avatar")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showPaywall) { PaywallView() }
            .sheet(isPresented: $choosingCompanion) { companionPicker }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private var drapeKey: String { sizeLabel + "|" + (companion.map { $0.key + "|" + $0.size } ?? "") }

    private var regions: [RegionFit] {
        analysis.sizes.first { $0.label == sizeLabel }?.regions.filter { $0.verdict != .insufficientData } ?? []
    }

    private var companionRegions: [RegionFit] {
        guard let companion else { return [] }
        return companion.analysis.sizes.first { $0.label == companion.size }?.regions.filter { $0.verdict != .insufficientData } ?? []
    }

    /// Said over the scene while the garments are cut and draped (a few seconds).
    private var loadingBadge: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(avatar == nil || drapingSize == nil ? String(localized: "Preparing your avatar…")
                : String(localized: "Putting on size \(drapingSize ?? sizeLabel)…"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("This takes a few seconds.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    /// With two pieces on, a button for each to take it off the view and back: an outer
    /// one (a coat) otherwise hides what is worn under it.
    @ViewBuilder
    private var layerToggles: some View {
        if let companion, (avatar?.layers.count ?? 0) > 1 {
            HStack(spacing: 8) {
                ForEach([(0, spec.category.title), (1, companion.spec.category.title)], id: \.0) { index, title in
                    let shown = !hiddenLayers.contains(index)
                    Button {
                        withAnimation(.snappy) {
                            if shown {
                                // Never both off: the other comes back.
                                hiddenLayers = [index]
                            } else {
                                hiddenLayers.remove(index)
                            }
                        }
                    } label: {
                        Label(title, systemImage: shown ? "eye.fill" : "eye.slash")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(shown ? 0.45 : 0.25), in: Capsule())
                            .foregroundStyle(shown ? Color.white : Color.white.opacity(0.6))
                    }
                    .accessibilityLabel(Text(shown ? "Hide \(title)" : "Show \(title)"))
                }
            }
            .padding(.top, 6)
            .sensoryFeedback(.selection, trigger: hiddenLayers)
        }
    }

    /// The colour key, over the top of the scene.
    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(FitTone.allCases, id: \.self) { tone in
                HStack(spacing: 4) {
                    Circle().fill(tone.color).frame(width: 9, height: 9)
                    Text(tone.title).lineLimit(1)
                }
            }
        }
        .font(.caption2.weight(.semibold))
        .minimumScaleFactor(0.7)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.45), in: Capsule())
        .padding(.top, 8)
    }

    /// How each piece sits, in a tailor's words, over the bottom of the scene.
    private var tailorCard: some View {
        let pieces: [(GarmentCategory, [RegionFit])] = [(spec.category, regions)]
            + (companion.map { c in
                [(c.spec.category, c.analysis.sizes.first { $0.label == c.size }?.regions ?? [])]
            } ?? [])
        let lines = pieces.compactMap { category, regions -> (String, String)? in
            let phrases = FitExplanation.tailorPhrases(regions, trousers: !category.isTop)
            return phrases.isEmpty ? nil : (category.title, phrases.joined(separator: " · "))
        }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.0) { line in
                Text("**\(line.0)**  \(line.1)")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .opacity(lines.isEmpty ? 0 : 1)
    }

    /// Front, side and back: turns the avatar there, the garment swinging as it goes.
    private var viewButtons: some View {
        let views: [(LocalizedStringKey, Float)] = [("Front view", 0), ("Side view", -.pi / 2), ("Back view", .pi)]
        return HStack(spacing: 8) {
            ForEach(views.indices, id: \.self) { i in
                Button {
                    facing = views[i].1
                    facingTurn += 1
                } label: {
                    Text(views[i].0)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: Capsule())
                }
                .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 4)
        .sensoryFeedback(.selection, trigger: facingTurn)
    }

    /// Each fit line that has something to say, labelled where it is.
    private func labels(_ avatar: Avatar) -> [SceneLabel] {
        avatar.layers.enumerated().filter { !hiddenLayers.contains($0.offset) }.flatMap { index, layer in
            let trousers = layer.fit.kind == .trousers
            // The layers are this garment, then the one worn with it.
            let verdicts = index == 0 ? regions : companionRegions
            return layer.fitLines.compactMap { line -> SceneLabel? in
                var text = line.text(trousers: trousers)
                // The waistband says the verdict in the panel's own words.
                if line.kind == .waistband, let waist = verdicts.first(where: { $0.region == .waist }) {
                    text = waist.verdict == .ideal ? nil : FitZone.waist.title + ": " + waist.verdictTitle
                }
                // A hem that sits as usual still says where it ends: "6 cm above the knee".
                if text == nil, line.kind == .hem, let ends = layer.placements.first(where: { $0.edge != .sleeve }) {
                    text = ends.text
                }
                guard let text else { return nil }
                return SceneLabel(id: "\(index)-\(line.kind.rawValue)", position: line.anchor, normal: line.normal,
                                  side: line.anchor.x >= 0 ? 1 : -1, text: text, tone: line.tone)
            }
        }
    }

    /// Plays the garments being put on: dropped onto the body, falling and settling, at
    /// the 30 frames a second they were simulated at.
    private func play() async {
        let count = avatar?.layers.map(\.frames.count).max() ?? 0
        guard count > 0 else { return }
        for k in 0..<count {
            guard !Task.isCancelled else { break }
            frame = k
            try? await Task.sleep(for: .milliseconds(33))
        }
        frame = nil
    }

    /// Runs the cloth simulation off the main thread.
    private func drape(_ body: BodyProfile) async {
        let companionNow = companion.map { $0.key + "|" + $0.size }
        if lastMain != nil, lastMain != sizeLabel {
            drapingSize = sizeLabel
        } else if let companion, companionNow != lastCompanion {
            drapingSize = companion.size
        } else {
            drapingSize = lastMain == nil ? nil : sizeLabel
        }
        lastMain = sizeLabel
        lastCompanion = companionNow
        draping = true
        guard var measured = Avatar.Measurements(body), let size = spec.sizes.first(where: { $0.label == sizeLabel }) else {
            draping = false
            return
        }
        measured.sex = measured.sex ?? BodySex(rawValue: sexRaw)
        let m = measured
        var fits: [Avatar.GarmentFit] = []
        var fit = AvatarFitMapper.fit(spec: spec, size: size, body: body, regions: regions, name: productName)
        fit.fabric = AvatarFitMapper.fabric(spec: spec, material: material)
        fits.append(fit)
        if let companion, let size = companion.spec.sizes.first(where: { $0.label == companion.size }) {
            var other = AvatarFitMapper.fit(spec: companion.spec, size: size, body: body, regions: companionRegions,
                                            name: companion.name)
            other.fabric = AvatarFitMapper.fabric(spec: companion.spec, material: companion.material)
            fits.append(other)
        }
        // The body straight away, then the garments put on it under gravity.
        if avatar == nil {
            let bare = await Task.detached(priority: .userInitiated) { Avatar(m) }.value
            guard !Task.isCancelled else { return }
            show(bare)
        }
        let worn = fits
        let draped = await Task.detached(priority: .userInitiated) { Avatar(m, garments: worn, detail: .animated) }.value
        guard !Task.isCancelled else { return }
        draping = false
        frame = draped.layers.contains { !$0.frames.isEmpty } ? 0 : nil
        show(draped)
        await play()
    }

    private func show(_ new: Avatar) {
        avatar = new
        revision += 1
    }

    // MARK: Panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if spec.sizes.count > 1 {
                    Picker("Size", selection: $sizeLabel) {
                        ForEach(spec.sizes, id: \.label) { Text($0.label).tag($0.label) }
                    }
                    .pickerStyle(.segmented)
                }
                regionRows(regions)
                placementRows(layer: 0)
                if let body = profiles.first?.profile { reliability(body) }
                companionSection
                details
                Text("Blue fits, yellow is loose, red is long, purple is tight, orange is short. Glowing lines are where the seams and hems fall; white dashes are where they belong on your body. The garment is cut to the size chart and settles on your body under its own weight, as far as its fibres stretch. Without the product's own pattern this is a model of the garment, not the real one.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(Theme.Spacing.m)
        }
        .frame(maxHeight: 330)
        .background(.bar)
        .sensoryFeedback(.selection, trigger: sizeLabel)
    }

    private func regionRows(_ regions: [RegionFit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(regions, id: \.region) { r in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: r.severity.symbol).foregroundStyle(r.severity.color)
                    Text(r.region.title)
                    Spacer()
                    Text(r.detailText).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
            }
        }
    }

    /// Where the garment's hem, legs and sleeves end on the body, as the draped avatar
    /// shows them: "Hem: 6 cm above the knee", "Legs: 3 cm past the ankle".
    @ViewBuilder
    private func placementRows(layer: Int) -> some View {
        if frame == nil, !draping, let avatar, avatar.layers.indices.contains(layer) {
            let placements = avatar.layers[layer].placements
            if !placements.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(placements.indices, id: \.self) { i in
                        let p = placements[i]
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: p.usual ? "ruler" : "exclamationmark.circle")
                                .foregroundStyle(p.usual ? Color.secondary : Color.orange)
                            Text(p.edge.title)
                            Spacer()
                            Text(p.text + (p.estimated ? " " + String(localized: "(estimated)") : ""))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
    }

    /// How sure the measurements this fit rests on are: the ones whose range is wide
    /// enough to change the verdict are named with their range.
    @ViewBuilder
    private func reliability(_ body: BodyProfile) -> some View {
        let dims = regions.compactMap(\.region.dimension)
        let unsure = dims.compactMap { d -> (BodyDimension, MeasurementAssessment)? in
            guard let a = body.assessment(d), !a.verified, a.high - a.low > 4 else { return nil }
            return (d, a)
        }
        .sorted { $0.1.high - $0.1.low > $1.1.high - $1.1.low }
        if !dims.isEmpty {
            if unsure.isEmpty {
                Label("Your measurements for this fit are reliable.", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(unsure.prefix(3)), id: \.0) { item in
                        Text("\(item.0.title) could be \(Int(item.1.low.rounded()))–\(Int(item.1.high.rounded())) cm")
                    }
                    Text("The fit may change within these ranges; measuring them with a tape makes it surer.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    /// The second piece: a button to add one, or the one worn with its size and verdicts.
    @ViewBuilder
    private var companionSection: some View {
        if let companion {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    Label(companion.name, systemImage: companion.spec.category.isTop ? "tshirt" : "figure.walk")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        self.companion = nil
                        hiddenLayers = []
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Take it off"))
                }
                if companion.spec.sizes.count > 1 {
                    sizeChips(companion.spec.sizes.map(\.label), selected: companion.size) { self.companion?.size = $0 }
                }
                regionRows(companion.analysis.sizes.first { $0.label == companion.size }?.regions
                    .filter { $0.verdict != .insufficientData } ?? [])
                placementRows(layer: 1)
            }
        } else if spec.category != .dress {
            Button {
                choosingCompanion = true
            } label: {
                Label(spec.category.isTop ? LocalizedStringKey("Wear it with trousers") : LocalizedStringKey("Wear it with a top"), systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    /// The other piece's sizes as a row of buttons, like this garment's picker but
    /// scrolling, since trouser sizes (28–40) can be many.
    private func sizeChips(_ labels: [String], selected: String, choose: @escaping (String) -> Void) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(labels, id: \.self) { label in
                        Button {
                            choose(label)
                        } label: {
                            Text(label)
                                .font(.subheadline.weight(label == selected ? .semibold : .regular))
                                .frame(minWidth: 36)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(label == selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .foregroundStyle(.primary)
                        .id(label)
                        .accessibilityAddTraits(label == selected ? .isSelected : [])
                    }
                }
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
        .sensoryFeedback(.selection, trigger: selected)
    }

    /// Garments analysed earlier that go with this one: trousers for a top, tops for trousers.
    private var companionPicker: some View {
        let wantTop = !spec.category.isTop
        // A dress goes with neither.
        let candidates = saved.filter { $0.spec.map { $0.category.isTop == wantTop && $0.category != .dress } ?? false }
        return NavigationStack {
            Group {
                if candidates.isEmpty {
                    ContentUnavailableView(wantTop ? LocalizedStringKey("No tops analysed yet") : LocalizedStringKey("No trousers analysed yet"),
                                           systemImage: wantTop ? "tshirt" : "figure.walk",
                                           description: Text("Check the fit of one and it will appear here."))
                } else {
                    List(candidates, id: \.productKey) { item in
                        Button {
                            pick(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let brand = item.brand { Text(brand).font(.caption).foregroundStyle(.secondary) }
                                    Text(item.productName ?? String(localized: "Garment")).lineLimit(2)
                                }
                                Spacer()
                                if let size = item.analysis?.recommendedSize?.label {
                                    Text(size).font(.headline.monospaced())
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(wantTop ? LocalizedStringKey("Add a top") : LocalizedStringKey("Add trousers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingCompanion = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func pick(_ item: SavedAnalysis) {
        guard let spec = item.spec, let saved = item.analysis else { return }
        // Judged again on the body as it is now: a saved verdict may predate a rescan or
        // a fix in the fit engine, and the avatar is built from the current body.
        let analysis = profiles.first?.profile.map { FitEngine().analyze(body: $0, garment: spec) } ?? saved
        let size = analysis.recommendedSize?.label ?? analysis.ranked.first?.label ?? spec.sizes.first?.label
        guard let size else { return }
        companion = Companion(key: item.productKey, name: item.productName ?? String(localized: "Garment"), spec: spec,
                              analysis: analysis, material: item.material, size: size)
        choosingCompanion = false
    }

    // MARK: Premium details

    @ViewBuilder
    private var details: some View {
        if container.isPremium {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                if let zones = avatar?.fitReport, !zones.isEmpty {
                    Text("Zone by zone").font(.footnote.weight(.semibold))
                    zoneList(zones)
                }
                comparisonSection
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                Label("Zone by zone and all sizes compared ★", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    /// The simulated zones, tightest first.
    private func zoneList(_ zones: [FitZone: ZoneReport]) -> some View {
        let sorted = zones.values.sorted { $0.tension > $1.tension || ($0.tension == $1.tension && $0.zone.rawValue < $1.zone.rawValue) }
        let range = comparison?.first { $0.label == sizeLabel }?.range ?? [:]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(sorted, id: \.zone) { z in
                HStack(spacing: 6) {
                    Circle().fill(z.tension.color).frame(width: 9, height: 9)
                    Text(z.zone.title)
                    Spacer()
                    Text(zoneDetail(z, range: range[z.zone])).foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }

    private func zoneDetail(_ z: ZoneReport, range: ClosedRange<ZoneTension>?) -> String {
        var text = z.tension.title
        if let range, range.lowerBound != range.upperBound {
            text = String(localized: "\(range.lowerBound.title) to \(range.upperBound.title)")
        }
        if z.stretchPercent >= 1 {
            text += " · " + String(localized: "stretched \(Int(z.stretchPercent.rounded()))%")
        } else if z.tension == .loose {
            text += " · " + String(localized: "\(z.gapCm.formatted(.number.precision(.fractionLength(0...1)))) cm off the body")
        }
        if let d = z.lengthDeltaCm, abs(d) >= 1 {
            let cm = abs(d).formatted(.number.precision(.fractionLength(0)))
            text += " · " + (d > 0 ? String(localized: "\(cm) cm long") : String(localized: "\(cm) cm short"))
        }
        return text
    }

    /// Drapes every size and ranks them by how they sit; where the body's measurements
    /// are uncertain, also on the smaller and larger body they allow.
    @ViewBuilder
    private var comparisonSection: some View {
        if spec.sizes.count > 1 {
            if let comparison {
                let best = Avatar.best(comparison)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(comparison, id: \.label) { drape in
                        HStack(spacing: 6) {
                            Text(drape.label).font(.footnote.weight(drape.label == best?.label ? .bold : .regular))
                                .frame(minWidth: 34, alignment: .leading)
                            ForEach(drape.zones.values.sorted { $0.zone.rawValue < $1.zone.rawValue }, id: \.zone) { z in
                                Circle().fill(z.tension.color).frame(width: 8, height: 8)
                            }
                            Spacer()
                            if !drape.uncertainZones.isEmpty {
                                Text("depends on \(drape.uncertainZones.map(\.title).joined(separator: ", "))")
                                    .font(.caption2).foregroundStyle(.orange).lineLimit(1)
                            }
                        }
                    }
                    if let best {
                        Text("By the simulation, \(best.label) sits best.")
                            .font(.footnote.weight(.semibold))
                    }
                }
            } else {
                Button {
                    Task { await compareSizes() }
                } label: {
                    if comparing {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Compare all sizes on my body", systemImage: "square.stack.3d.up").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(comparing)
            }
        }
    }

    private func compareSizes() async {
        guard let body = profiles.first?.profile, var measured = Avatar.Measurements(body) else { return }
        measured.sex = measured.sex ?? BodySex(rawValue: sexRaw)
        let m = measured
        comparing = true
        let fabric = AvatarFitMapper.fabric(spec: spec, material: material)
        let sizes: [(label: String, fit: Avatar.GarmentFit)] = spec.sizes.map { size in
            var fit = AvatarFitMapper.fit(spec: spec, size: size, body: body, name: productName)
            fit.fabric = fabric
            return (size.label, fit)
        }
        let (low, high) = AvatarFitMapper.bodyRange(body, around: m)
        let result = await Task.detached(priority: .userInitiated) {
            Avatar.compare(sizes: sizes, body: m, low: low, high: high)
        }.value
        comparing = false
        guard !Task.isCancelled else { return }
        withAnimation { comparison = result }
    }
}

/// "My avatar": the body from the measurements, fine-tuned with sliders and saved back.
struct AvatarEditorView: View {
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var values: [BodyDimension: Double] = [:]
    @State private var original: [BodyDimension: Double] = [:]
    @State private var avatar: Avatar?
    @State private var revision = 0
    @StateObject private var labelModel = LandmarkLabels()

    private static let editable: [BodyDimension] = [.shoulderWidth, .chest, .waist, .hip, .thigh, .armLength, .inseam]

    var body: some View {
        VStack(spacing: 0) {
            if let base = profiles.first?.profile, let m = Avatar.Measurements(adjusted(base)) {
                ZStack {
                    if let avatar {
                        AvatarSceneView(avatar: avatar, revision: revision, fitColors: false,
                                        labels: Self.sceneLabels(avatar, labels(m)), labelModel: labelModel)
                        LandmarkOverlay(model: labelModel)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxHeight: .infinity)
                // A quick coarse body while a slider moves, the full one once it stops.
                .task(id: m) {
                    let quick = await Task.detached(priority: .userInitiated) { Avatar(m, detail: .preview) }.value
                    guard !Task.isCancelled else { return }
                    if avatar == nil { show(quick) }
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    show(quick)
                    let full = await Task.detached(priority: .userInitiated) { Avatar(m) }.value
                    guard !Task.isCancelled else { return }
                    show(full)
                }
                ScrollView {
                    VStack(spacing: Theme.Spacing.s) {
                        ForEach(Self.editable, id: \.self) { d in
                            if let start = original[d] {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(d.title)
                                        Spacer()
                                        Text("\(values[d] ?? start, format: .number.precision(.fractionLength(1))) cm")
                                            .monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.subheadline)
                                    Slider(value: binding(d, start: start), in: (start * 0.85)...(start * 1.15), step: 0.5)
                                }
                            }
                        }
                        Button("Save to my measurements") { save(base) }
                            .buttonStyle(.primary)
                            .disabled(values == original)
                    }
                    .padding(Theme.Spacing.m)
                }
                .frame(maxHeight: 330)
                .background(.bar)
            } else {
                ContentUnavailableView("Scan or enter your measurements first", systemImage: "figure.stand")
            }
        }
        .background(Theme.screenBackground)
        .navigationTitle("My avatar")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard original.isEmpty, let base = profiles.first?.profile else { return }
            for d in Self.editable { if let v = base[d]?.cm { original[d] = v } }
            values = original
        }
    }

    private func show(_ new: Avatar) {
        avatar = new
        revision += 1
    }

    /// The named body points as labels.
    static func sceneLabels(_ avatar: Avatar, _ texts: [Avatar.Landmark.Kind: String]) -> [SceneLabel] {
        avatar.landmarks.compactMap { l in
            texts[l.kind].map { SceneLabel(id: l.kind.rawValue, position: l.position, normal: l.normal, side: l.side, text: $0) }
        }
    }

    /// Body points named, with the measurement that belongs to each.
    private func labels(_ m: Avatar.Measurements) -> [Avatar.Landmark.Kind: String] {
        func cm(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) + " cm" }
        var out = Dictionary(uniqueKeysWithValues: Avatar.Landmark.Kind.allCases.map { ($0, $0.title) })
        out[.shoulder] = Avatar.Landmark.Kind.shoulder.title + " · " + cm(m.shoulderWidth)
        out[.chest] = Avatar.Landmark.Kind.chest.title + " · " + cm(m.chest)
        out[.waist] = Avatar.Landmark.Kind.waist.title + " · " + cm(m.waist)
        out[.hip] = Avatar.Landmark.Kind.hip.title + " · " + cm(m.hip)
        out[.thigh] = Avatar.Landmark.Kind.thigh.title + " · " + cm(m.thigh)
        out[.wrist] = Avatar.Landmark.Kind.wrist.title + " · " + String(localized: "arm \(cm(m.armLength))")
        out[.crotch] = Avatar.Landmark.Kind.crotch.title + " · " + String(localized: "inseam \(cm(m.inseam))")
        return out
    }

    private func binding(_ d: BodyDimension, start: Double) -> Binding<Double> {
        Binding(get: { values[d] ?? start }, set: { values[d] = $0 })
    }

    private func adjusted(_ base: BodyProfile) -> BodyProfile {
        var p = base
        for (d, v) in values where v != original[d] { p[d] = .manual(v) }
        return p
    }

    private func save(_ base: BodyProfile) {
        var p = adjusted(base)
        p.createdAt = Date()
        if let stored = try? StoredBodyProfile(profile: p) {
            modelContext.insert(stored)
            try? modelContext.save()
            AppSounds.shared.play(.saved)
            original = values
        }
    }
}

extension FitZone {
    var title: String {
        switch self {
        case .shoulder: String(localized: "Shoulders")
        case .chest: String(localized: "Chest")
        case .back: String(localized: "Back")
        case .waist: String(localized: "Waist")
        case .abdomen: String(localized: "Belly")
        case .sleeve: String(localized: "Sleeves")
        case .elbow: String(localized: "Elbows")
        case .hip: String(localized: "Hips")
        case .thigh: String(localized: "Thighs")
        case .knee: String(localized: "Knees")
        case .hem: String(localized: "Hems")
        }
    }
}

extension ZoneTension {
    var title: String {
        switch self {
        case .loose: String(localized: "Loose")
        case .comfortable: String(localized: "Comfortable")
        case .slightlyTight: String(localized: "Slightly tight")
        case .tight: String(localized: "Tight")
        case .veryTight: String(localized: "Very tight")
        }
    }

    /// The fit map's colours.
    var color: Color {
        switch self {
        case .loose: Color(red: 0.3, green: 0.55, blue: 0.78)
        case .comfortable: Color(red: 0.36, green: 0.76, blue: 0.6)
        case .slightlyTight: Color(red: 0.98, green: 0.84, blue: 0.32)
        case .tight: Color(red: 0.97, green: 0.58, blue: 0.24)
        case .veryTight: Color(red: 0.9, green: 0.3, blue: 0.28)
        }
    }
}
