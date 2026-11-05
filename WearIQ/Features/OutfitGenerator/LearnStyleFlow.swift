import AvatarEngine
import BodyMeasurementEngine
import BodyScanVision
import FitEngine
import OutfitRecommendationEngine
import SwiftData
import SwiftUI
import WearIQCore

/// What the app learned about how the user likes to wear clothes, once confirmed.
struct LearnedStyle: Codable, Equatable {
    var style: StyleLearning.Style
    var topColor: ColorFamily?
    var bottomColor: ColorFamily?

    static let key = "learnedStyle"

    static var current: LearnedStyle? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(LearnedStyle.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// "Learn your style", under the style card: what was learned, or the button to start.
struct LearnStyleCard: View {
    @AppStorage(LearnedStyle.key) private var stored: Data?
    @State private var learning = false

    private var learned: LearnedStyle? { stored.flatMap { try? JSONDecoder().decode(LearnedStyle.self, from: $0) } }

    var body: some View {
        Card {
            Label("Your way of wearing clothes", systemImage: "figure.dress.line.vertical.figure")
                .font(.headline)
            if let learned, learned.style.confirmed {
                Text(learned.summary).font(.subheadline).foregroundStyle(.secondary)
                Text("Every check now also says which size suits your style.").font(.footnote).foregroundStyle(.secondary)
                Button("Learn it again") { learning = true }.font(.subheadline)
            } else {
                Text("Wear the clothes you love most and stand in front of the phone. WearIQ sees how you like them to sit (close, regular or roomy) and your colours, and then tells you which size suits your style, not just your body.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { learning = true } label: { Label("Learn my style", systemImage: "sparkles") }
                    .buttonStyle(.primary)
            }
        }
        .fullScreenCover(isPresented: $learning) { LearnStyleFlow { learning = false } }
    }
}

extension LearnedStyle {
    var summary: String {
        var parts = [String(localized: "Tops: \(style.topFit.title.lowercased())")]
        if style.wearsSkirts {
            parts.append(String(localized: "skirts and dresses") + (style.skirtLength.map { " (" + $0.title + ")" } ?? ""))
        } else {
            parts.append(String(localized: "Bottoms: \(style.bottomFit.title.lowercased())")
                         + (style.legCut.map { ", " + $0.title.lowercased() } ?? ""))
        }
        let colors = [topColor, bottomColor].compactMap { $0?.title.lowercased() }
        if !colors.isEmpty { parts.append(String(localized: "Colours: \(colors.joined(separator: ", "))")) }
        return parts.joined(separator: " · ")
    }
}

extension StyleLearning.Length {
    var title: String {
        switch self {
        case .mini: String(localized: "mini")
        case .knee: String(localized: "knee length")
        case .midi: String(localized: "midi")
        case .maxi: String(localized: "maxi")
        }
    }
}

/// Tutorial → photo → what was learned, to confirm or correct.
struct LearnStyleFlow: View {
    let onFinished: () -> Void
    @Environment(AppContainer.self) private var container
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @State private var step = 0
    @State private var capture: StyleCaptureModel?
    @State private var result: LearnedStyle?

    private var body_: BodyProfile? { profiles.of(nil).first?.profile }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    StyleResultView(learned: result) { confirmed in
                        confirmed.save()
                        onFinished()
                    }
                } else if let capture {
                    StyleCaptureView(model: capture) { observation, top, bottom in
                        guard let body = body_ else { return }
                        result = LearnedStyle(style: StyleLearning.infer(observation, body: body), topColor: top, bottomColor: bottom)
                        capture.stop()
                    }
                } else if body_ == nil {
                    ContentUnavailableView("Measure yourself first", systemImage: "ruler",
                                           description: Text("Your style is read against your own measurements: scan once or enter them in the profile."))
                } else {
                    intro
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { capture?.stop(); onFinished() } } }
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Image(systemName: "tshirt.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(maxWidth: .infinity)
                Text("Learn your style").font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Label("Put on your favourite outfit: the clothes you feel best in.", systemImage: "heart.fill")
                    Label("Lean the phone upright at about waist height, front camera towards you.", systemImage: "iphone")
                    Label("Step back until you're seen head to toe, feet a little apart, arms slightly away from your body.", systemImage: "figure.stand")
                    Label("Hold still for a moment: the photo takes itself. It's read on this phone and deleted.", systemImage: "lock.shield")
                }
                .font(.body)
                Button {
                    let model = StyleCaptureModel(heightCm: body_?[.height]?.cm ?? 170)
                    capture = model
                    Task { await model.start() }
                } label: {
                    Text("Start").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
            }
            .padding(Theme.Spacing.l)
        }
    }
}

/// The camera, with a hint until the user is in place and still, then a short countdown.
struct StyleCaptureView: View {
    @Bindable var model: StyleCaptureModel
    let onCaptured: (StyleLearning.Observation, ColorFamily?, ColorFamily?) -> Void

    var body: some View {
        ZStack {
            CameraPreview(session: model.camera.session).ignoresSafeArea()
            VStack {
                Spacer()
                Text(model.message)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding()
            }
        }
        .onChange(of: model.captured) { _, captured in
            if let captured { onCaptured(captured.observation, captured.top, captured.bottom) }
        }
    }
}

/// Watches the front camera until the whole body is in view and still, then reads the
/// clothes' outline and colours from a few frames.
@MainActor
@Observable
final class StyleCaptureModel {
    struct Captured: Equatable {
        var observation: StyleLearning.Observation
        var top: ColorFamily?
        var bottom: ColorFamily?
    }

    let camera = CameraController()
    private let vision = VisionBodyAnalyzer()
    private let heightCm: Double
    private(set) var message = String(localized: "Step back until you're seen head to toe.")
    private(set) var captured: Captured?
    private var steadySince: Date?
    private var lastWidth: Double?
    private var collected: [(StyleLearning.Observation, ColorFamily?, ColorFamily?)] = []

    init(heightCm: Double) {
        self.heightCm = heightCm
    }

    func start() async {
        camera.frameRate = 6
        let vision = vision, heightCm = heightCm
        camera.onFrame = { [weak self] buffer in
            let reading = Self.read(buffer, vision: vision, heightCm: heightCm)
            Task { @MainActor in self?.handle(reading) }
        }
        do {
            try await camera.start(position: .front)
        } catch {
            message = error.localizedDescription
        }
    }

    func stop() {
        camera.onFrame = nil
        camera.stop()
    }

    private func handle(_ reading: (StyleLearning.Observation, ColorFamily?, ColorFamily?)?) {
        guard captured == nil else { return }
        guard let reading, let chest = reading.0.chest else {
            message = String(localized: "Step back until you're seen head to toe.")
            steadySince = nil
            collected = []
            return
        }
        // Still: the chest outline changes by less than 3% between frames.
        if let last = lastWidth, abs(chest - last) / last > 0.03 {
            steadySince = nil
            collected = []
        }
        lastWidth = chest
        let now = Date()
        if steadySince == nil { steadySince = now }
        let held = now.timeIntervalSince(steadySince!)
        if held < 2 {
            message = String(localized: "Hold still…")
            return
        }
        collected.append(reading)
        message = String(localized: "Reading your outfit…")
        guard collected.count >= 6 else { return }
        captured = Self.combine(collected)
        AppSounds.shared.play(.success)
        stop()
    }

    /// Medians over the frames.
    private static func combine(_ readings: [(StyleLearning.Observation, ColorFamily?, ColorFamily?)]) -> Captured {
        func median(_ values: [Double?]) -> Double? {
            let v = values.compactMap { $0 }.sorted()
            return v.isEmpty ? nil : v[v.count / 2]
        }
        func mode(_ values: [ColorFamily?]) -> ColorFamily? {
            let counts = Dictionary(grouping: values.compactMap { $0 }, by: { $0 }).mapValues(\.count)
            return counts.max { $0.value < $1.value }?.key
        }
        let o = readings.map(\.0)
        let covered = o.filter(\.legsCovered).count * 2 > o.count
        let observation = StyleLearning.Observation(
            chest: median(o.map(\.chest)), waist: median(o.map(\.waist)), hip: median(o.map(\.hip)),
            thigh: covered ? nil : median(o.map(\.thigh)), lowerLeg: covered ? nil : median(o.map(\.lowerLeg)),
            legsCovered: covered, hemHeight: covered ? median(o.map(\.hemHeight)) : nil, onePiece: false)
        return Captured(observation: observation, top: mode(readings.map(\.1)), bottom: mode(readings.map(\.2)))
    }

    /// One frame: the outline's widths and the clothes' colours, or nil when the whole
    /// body isn't in view.
    nonisolated static func read(_ buffer: CVPixelBuffer, vision: VisionBodyAnalyzer, heightCm: Double)
        -> (StyleLearning.Observation, ColorFamily?, ColorFamily?)? {
        guard let frame = vision.turnFrame(buffer, time: 0),
              let reading = RotationScanAnalyzer().reading(frame, heightCm: heightCm,
                                                           levelFractions: [.chest: 0.27, .waist: 0.39, .hip: 0.5]),
              reading.top > 0.02, reading.floor < 0.985, reading.floor - reading.top > 0.45 else { return nil }
        let w = Double(frame.mask.width), h = Double(frame.mask.height)
        let cmPerX = heightCm / ((reading.floor - reading.top) * h) * w
        var o = StyleLearning.Observation(chest: reading.levels[.chest]?.widthCm, waist: reading.levels[.waist]?.widthCm,
                                          hip: reading.levels[.hip]?.widthCm)
        // Legs: apart (trousers) or one shape (a skirt or dress), from the outline rows.
        func rows(at fraction: Double) -> [OutlineSpan]? {
            let y = reading.top + fraction * (reading.floor - reading.top)
            return reading.outline.min { abs($0.y - y) < abs($1.y - y) }?.spans
        }
        let thighSpans = rows(at: 0.6) ?? [], shinSpans = rows(at: 0.86) ?? []
        if thighSpans.count >= 2 {
            o.thigh = thighSpans.map { ($0.right - $0.left) * cmPerX }.max()
            if shinSpans.count >= 2 { o.lowerLeg = shinSpans.map { ($0.right - $0.left) * cmPerX }.max() }
        } else {
            o.legsCovered = true
            // The hem: the first row down where the legs show apart.
            let below = reading.outline.filter { $0.y > reading.top + 0.5 * (reading.floor - reading.top) }.sorted { $0.y < $1.y }
            if let apart = below.first(where: { $0.spans.count >= 2 }) {
                o.hemHeight = (reading.floor - apart.y) / (reading.floor - reading.top)
            }
        }
        let colors = Self.colors(buffer, joints: frame.joints)
        return (o, colors.top, colors.bottom)
    }

    /// The main colour of the top (the torso between shoulders and hips) and the bottom
    /// (along each thigh, hip to knee: the middle of that box is the gap between the legs).
    nonisolated static func colors(_ buffer: CVPixelBuffer, joints: [BodyJoint: Point2D]) -> (top: ColorFamily?, bottom: ColorFamily?) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (nil, nil) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Double, _ y: Double) -> GarmentColor.RGB? {
            let px = Int(x * Double(w)), py = Int(y * Double(h))
            guard px >= 0, px < w, py >= 0, py < h else { return nil }
            let p = base.advanced(by: py * row + px * 4).assumingMemoryBound(to: UInt8.self)
            return GarmentColor.RGB(Double(p[2]) / 255, Double(p[1]) / 255, Double(p[0]) / 255)
        }
        func name(_ pixels: [GarmentColor.RGB]) -> ColorFamily? {
            GarmentColor.dominant(pixels).map { ColorFamily.nearest(red: $0.color.r, green: $0.color.g, blue: $0.color.b) }
        }
        var top: ColorFamily?
        if let ls = joints[.leftShoulder], let rs = joints[.rightShoulder], let lh = joints[.leftHip], let rh = joints[.rightHip] {
            let y0 = (ls.y + rs.y) / 2, y1 = (lh.y + rh.y) / 2
            let x0 = min(ls.x, rs.x, lh.x, rh.x), x1 = max(ls.x, rs.x, lh.x, rh.x)
            var pixels: [GarmentColor.RGB] = []
            for j in 0..<24 {
                let y = y0 + (y1 - y0) * (0.15 + 0.7 * Double(j) / 23)
                for i in 0..<24 {
                    if let p = pixel(x0 + (x1 - x0) * (0.25 + 0.5 * Double(i) / 23), y) { pixels.append(p) }
                }
            }
            top = name(pixels)
        }
        var bottom: ColorFamily?
        if let lh = joints[.leftHip], let rh = joints[.rightHip] {
            // Half a thigh's width either side of the line from hip to knee.
            let half = abs(lh.x - rh.x) * 0.22
            var pixels: [GarmentColor.RGB] = []
            for (hip, knee) in [(lh, joints[.leftKnee]), (rh, joints[.rightKnee])] {
                guard let knee else { continue }
                for j in 0..<20 {
                    let t = 0.12 + 0.68 * Double(j) / 19
                    let cx = hip.x + (knee.x - hip.x) * t, cy = hip.y + (knee.y - hip.y) * t
                    for i in 0..<9 {
                        if let p = pixel(cx + half * (Double(i) / 4 - 1), cy) { pixels.append(p) }
                    }
                }
            }
            bottom = name(pixels)
        }
        return (top, bottom)
    }
}

/// What was learned, with every part correctable, and a confirmation.
struct StyleResultView: View {
    @State var learned: LearnedStyle
    let onConfirm: (LearnedStyle) -> Void
    @AppStorage("bodySex") private var sexRaw = ""
    @State private var sawSkirt = false

    /// Skirts are asked about only of women, or when the photo showed one.
    private var offersSkirts: Bool { BodySex(rawValue: sexRaw) == .female || sawSkirt }

    var body: some View {
        Form {
            Section {
                Text("Here's what your outfit says about how you like to wear clothes. Correct anything that's off.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Tops") {
                Picker("How they sit", selection: $learned.style.topFit) {
                    ForEach(FitStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Colour", selection: $learned.topColor) {
                    Text("Not sure").tag(ColorFamily?.none)
                    ForEach(ColorFamily.allCases, id: \.self) { Text($0.title).tag(ColorFamily?.some($0)) }
                }
            }
            Section {
                if offersSkirts {
                    Toggle("I mostly wear skirts or dresses", isOn: $learned.style.wearsSkirts)
                }
                if learned.style.wearsSkirts {
                    Picker("Length", selection: $learned.style.skirtLength) {
                        Text("Not sure").tag(StyleLearning.Length?.none)
                        ForEach([StyleLearning.Length.mini, .knee, .midi, .maxi], id: \.self) { Text($0.title).tag(StyleLearning.Length?.some($0)) }
                    }
                } else {
                    Picker("How they sit", selection: $learned.style.bottomFit) {
                        ForEach(FitStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Leg cut", selection: $learned.style.legCut) {
                        Text("Not sure").tag(LegCut?.none)
                        ForEach(LegCut.allCases, id: \.self) { Text($0.title).tag(LegCut?.some($0)) }
                    }
                }
                Picker("Colour", selection: $learned.bottomColor) {
                    Text("Not sure").tag(ColorFamily?.none)
                    ForEach(ColorFamily.allCases, id: \.self) { Text($0.title).tag(ColorFamily?.some($0)) }
                }
            } header: {
                Text("Bottoms")
            } footer: {
                if offersSkirts {
                    Text("On: sizes are suggested for skirts and dresses, by their length. Off: for trousers, by how they sit and their leg cut.")
                }
            }
            Section {
                Button {
                    var confirmed = learned
                    confirmed.style.confirmed = true
                    onConfirm(confirmed)
                } label: {
                    Text("That's my style").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
            }
        }
        .navigationTitle("Your style")
        .onAppear { if learned.style.wearsSkirts { sawSkirt = true } }
    }
}

/// On a fit result: the size for the user's own style, when it differs.
struct StyleFitCard: View {
    let spec: GarmentSpec?
    let analysis: FitAnalysis
    @Environment(AppContainer.self) private var container
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @AppStorage(LearnedStyle.key) private var stored: Data?

    var body: some View {
        if container.activePersonID == nil, let spec, let body = profiles.of(nil).first?.profile,
           let learned = stored.flatMap({ try? JSONDecoder().decode(LearnedStyle.self, from: $0) }),
           let pick = StyleLearning.sizeForStyle(learned.style, spec: spec, body: body, analysis: analysis),
           let recommended = analysis.recommendedSize?.label {
            Label(String(localized: "\(recommended) fits you as the garment is cut; for your \(pick.fit.title.lowercased()) style, \(pick.size)."),
                  systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }
}

/// From what the user checked: what to wear with each piece.
struct ScanPairingsSection: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \SavedAnalysis.createdAt, order: .reverse) private var analyses: [SavedAnalysis]
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @AppStorage("bodySex") private var sexRaw = ""
    @AppStorage(LearnedStyle.key) private var stored: Data?

    /// Whoever the app is shopping for: their sex from their own profile.
    private var female: Bool {
        if let sex = profiles.of(container.activePersonID).first?.profile?.sex { return sex == .female }
        return BodySex(rawValue: sexRaw) == .female
    }

    var body: some View {
        let items = analyses.filter { $0.personID == container.activePersonID && $0.spec != nil }.prefix(5)
        if !items.isEmpty {
            Card {
                Label("To wear with what you checked", systemImage: "rectangle.on.rectangle.angled")
                    .font(.headline)
                ForEach(Array(items)) { saved in
                    if let spec = saved.spec {
                        let item = Pairing.Item(kind: spec.category.pairingKind, color: ColorFamily.named(in: saved.productName ?? ""),
                                                fit: spec.fitStyle.pairingFit)
                        let favourite = stored.flatMap { try? JSONDecoder().decode(LearnedStyle.self, from: $0) }?.topColor
                        let suggestions = Pairing.suggest(for: item, female: female, favourite: container.activePersonID == nil ? favourite : nil)
                        NavigationLink {
                            FitResultView(saved: saved)
                        } label: {
                            HStack(spacing: Theme.Spacing.s) {
                                ProductThumbnail(url: saved.imageURL, category: spec.category)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(saved.productName ?? String(localized: "Garment"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(suggestions.prefix(2).map(\.text).joined(separator: String(localized: " or ")))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                    if let size = saved.analysis?.recommendedSize?.label {
                                        Text("Your size: \(size)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Opens its size and the avatar"))
                    }
                }
            }
        }
    }
}

extension GarmentCategory {
    var pairingKind: Pairing.Kind {
        switch self {
        case .pants, .skirt, .shorts: .bottom
        case .dress: .dress
        case .jacket, .coat: .outerwear
        case .shirt, .tshirt, .sweater: .top
        }
    }
}

extension FitStyle {
    var pairingFit: Pairing.Fit {
        switch self {
        case .slim: .close
        case .regular: .regular
        case .relaxed, .oversized: .roomy
        }
    }
}

extension Pairing.Suggestion {
    var text: String {
        let colour = color.title.lowercased()
        return switch piece {
        case .miniSkirt: String(localized: "a \(colour) mini skirt")
        case .midiSkirt: String(localized: "a \(colour) midi skirt")
        case .slimJeans: String(localized: "\(colour) slim jeans")
        case .straightTrousers: String(localized: "\(colour) straight trousers")
        case .wideTrousers: String(localized: "\(colour) wide-leg trousers")
        case .tailoredTrousers: String(localized: "\(colour) tailored trousers")
        case .shorts: String(localized: "\(colour) shorts")
        case .fittedTop: String(localized: "a fitted \(colour) top")
        case .croppedTop: String(localized: "a cropped \(colour) top")
        case .relaxedShirt: String(localized: "a relaxed \(colour) shirt")
        case .knitTop: String(localized: "a \(colour) knit")
        case .tee: String(localized: "a \(colour) tee")
        case .denimJacket: String(localized: "a \(colour) denim jacket")
        case .blazer: String(localized: "a \(colour) blazer")
        case .trenchCoat: String(localized: "a \(colour) trench coat")
        }
    }
}

/// A checked product's photo, or its kind of garment when there's none.
struct ProductThumbnail: View {
    let url: URL?
    let category: GarmentCategory

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: category.isBottom ? "figure.walk" : "tshirt")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: 48, height: 60)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}
