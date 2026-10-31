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
    static func fit(spec: GarmentSpec, size: SizeEntry, body: BodyProfile) -> Avatar.GarmentFit {
        let isTrousers = spec.category == .pants
        var fit = Avatar.GarmentFit(kind: isTrousers ? .trousers : .top(longSleeves: spec.category != .tshirt))
        func diff(_ g: GarmentDimension, _ b: BodyDimension) -> Double? {
            guard let gv = size.values[g]?.cm, let bv = body[b]?.cm else { return nil }
            return gv - bv
        }
        func ease(_ g: GarmentDimension, _ b: BodyDimension, typical: Double) -> Double {
            guard let d = diff(g, b) else { return typical }
            return spec.chartKind == .garment ? d : typical + d
        }
        let style = spec.fitStyle
        if isTrousers {
            fit.waistEase = ease(.waist, .waist, typical: 1.5)
            fit.hipEase = ease(.hip, .hip, typical: [FitStyle.slim: 4, .regular: 7, .relaxed: 12, .oversized: 20][style] ?? 7)
            fit.thighEase = ease(.thigh, .thigh, typical: [FitStyle.slim: 5, .regular: 9, .relaxed: 15, .oversized: 24][style] ?? 9)
            fit.lengthDelta = diff(.inseam, .inseam) ?? diff(.outseam, .outseam) ?? 0
        } else {
            let chestTypical: Double = [FitStyle.slim: 7, .regular: 12, .relaxed: 19, .oversized: 30][style] ?? 12
            fit.chestEase = ease(.chest, .chest, typical: chestTypical)
            fit.waistEase = ease(.waist, .waist, typical: chestTypical + 3)
            fit.hipEase = fit.waistEase
            let lengthEase: Double = spec.category == .tshirt ? 18 : spec.category == .jacket ? 25 : 21
            if let d = diff(.bodyLength, .torsoLength) { fit.lengthDelta = spec.chartKind == .garment ? d - lengthEase : d }
            if let d = diff(.sleeveLength, .armLength) { fit.sleeveDelta = spec.chartKind == .garment ? d - 2.5 : d }
            // The chart's shoulder runs over the back; a scanned one is bone to bone.
            let shoulder = body[.shoulderWidth].map(FitEngine.acrossBack)
            if let gv = size.values[.shoulderWidth]?.cm, let bv = shoulder?.cm {
                let d = gv - bv
                fit.shoulderDelta = spec.chartKind == .garment ? d : d + (style == .oversized ? 7 : 0)
            } else if style == .oversized {
                fit.shoulderDelta = 7
            }
        }
        return fit
    }

    /// How the fabric stretches and drapes, from its composition when the product page
    /// gave one, otherwise from the category and the chart's stretch setting.
    static func fabric(spec: GarmentSpec, material: String?) -> Fabric {
        let knit = spec.category == .tshirt
        let fibres = FabricAdvice.fibres(in: material ?? "")
        guard !fibres.isEmpty else {
            var fabric: Fabric = knit ? .knit : .woven
            fabric.stretchLimit += Float(spec.stretch.comfortableStretch)
            return fabric
        }
        return Fabric(fibres: Dictionary(uniqueKeysWithValues: fibres.map { ($0.key.rawValue, $0.value) }), knit: knit)
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
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var saved: [SavedAnalysis]
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
                                                labels: frame == nil ? labels(avatar) : [], labelModel: labelModel,
                                                facing: facing, facingTurn: facingTurn)
                                LandmarkOverlay(model: labelModel)
                            } else {
                                ProgressView("Draping the fabric…")
                            }
                            VStack {
                                legend.allowsHitTesting(false)
                                Spacer()
                                tailorCard.allowsHitTesting(false)
                                viewButtons
                                Label("Drag to turn", systemImage: "hand.draw")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 6)
                                    .allowsHitTesting(false)
                            }
                        }
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
        avatar.layers.enumerated().flatMap { index, layer in
            let trousers = layer.fit.kind == .trousers
            return layer.fitLines.compactMap { line -> SceneLabel? in
                guard let text = line.text(trousers: trousers) else { return nil }
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
        guard let m = Avatar.Measurements(body), let size = spec.sizes.first(where: { $0.label == sizeLabel }) else { return }
        var fits: [Avatar.GarmentFit] = []
        var fit = AvatarFitMapper.fit(spec: spec, size: size, body: body)
        fit.fabric = AvatarFitMapper.fabric(spec: spec, material: material)
        fits.append(fit)
        if let companion, let size = companion.spec.sizes.first(where: { $0.label == companion.size }) {
            var other = AvatarFitMapper.fit(spec: companion.spec, size: size, body: body)
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
                    if companion.spec.sizes.count > 1 {
                        Menu(companion.size) {
                            ForEach(companion.spec.sizes, id: \.label) { size in
                                Button(size.label) { self.companion?.size = size.label }
                            }
                        }
                    }
                    Button {
                        self.companion = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Take it off"))
                }
                regionRows(companion.analysis.sizes.first { $0.label == companion.size }?.regions
                    .filter { $0.verdict != .insufficientData } ?? [])
            }
        } else {
            Button {
                choosingCompanion = true
            } label: {
                Label(spec.category.isTop ? LocalizedStringKey("Wear it with trousers") : LocalizedStringKey("Wear it with a top"), systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    /// Garments analysed earlier that go with this one: trousers for a top, tops for trousers.
    private var companionPicker: some View {
        let wantTop = !spec.category.isTop
        let candidates = saved.filter { $0.spec.map { $0.category.isTop == wantTop } ?? false }
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
        guard let spec = item.spec, let analysis = item.analysis else { return }
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
        guard let body = profiles.first?.profile, let m = Avatar.Measurements(body) else { return }
        comparing = true
        let fabric = AvatarFitMapper.fabric(spec: spec, material: material)
        let sizes: [(label: String, fit: Avatar.GarmentFit)] = spec.sizes.map { size in
            var fit = AvatarFitMapper.fit(spec: spec, size: size, body: body)
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
