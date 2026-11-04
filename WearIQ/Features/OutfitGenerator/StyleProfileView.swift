import OutfitRecommendationEngine
import SwiftData
import SwiftUI
import WearIQCore

/// "Your style": colours from skin tone, cuts from body shape (from the measurements)
/// and pieces from a style question. Free for everyone, at the top of the Style tab.
struct StyleProfileCard: View {
    @AppStorage("styleProfile") private var stored = ""
    @AppStorage("bodySex") private var sexRaw = ""
    @Query(sort: \StoredBodyProfile.createdAt, order: .reverse) private var profiles: [StoredBodyProfile]
    @State private var editing = false

    private var profile: StyleProfile? {
        stored.data(using: .utf8).flatMap { try? JSONDecoder().decode(StyleProfile.self, from: $0) }
    }

    private var shape: BodyShape? {
        guard let body = profiles.of(nil).first?.profile, let chest = body[.chest]?.cm, let waist = body[.waist]?.cm,
              let hip = body[.hip]?.cm else { return nil }
        return BodyShape.classify(chest: chest, waist: waist, hip: hip, shoulder: body[.shoulderWidth]?.cm,
                                  female: BodySex(rawValue: sexRaw) == .female)
    }

    var body: some View {
        Card {
            if let profile {
                HStack {
                    Label("Your style", systemImage: "paintpalette.fill").font(.headline)
                    Spacer()
                    Button("Change") { editing = true }.font(.subheadline)
                }
                section(profile.colorSeason.title, profile.colorSeason.explanation)
                swatches(profile.palette.flattering)
                Text("Keep away from your face: \(profile.palette.avoid.map(\.title).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let shape {
                    Divider()
                    section(shape.title, shape.advice)
                }
                Divider()
                section(profile.vibe.title, profile.vibe.pieces)
                advice(profile)
            } else {
                Label("Find your colours and cuts", systemImage: "paintpalette.fill").font(.headline)
                Text("A quick skin tone scan and three questions. With your measurements, WearIQ suggests the style, colours, fabrics and cuts that suit you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Start") { editing = true }
                    .buttonStyle(.primary)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .sheet(isPresented: $editing) { StyleQuestionsView(stored: $stored, initial: profile) }
    }

    /// What suits this build, the style the user likes measured against it, and how to
    /// put it together and look after it.
    @ViewBuilder
    private func advice(_ profile: StyleProfile) -> some View {
        let a = StyleAdvice.make(shape: shape, vibe: profile.vibe, occasion: profile.occasion ?? .everyday,
                                 ease: profile.ease ?? .fitted)
        Divider()
        if a.suitsChosen {
            Label("\(profile.vibe.title) suits your build.", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
        } else if let better = a.bestVibes.first {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(profile.vibe.title) works with care; \(better.title) may suit you better.", systemImage: "lightbulb.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(better.pieces).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        tips(String(localized: "Cuts"), a.cuts)
        tips(String(localized: "Fabrics"), a.fabrics)
        tips(String(localized: "Use sparingly"), a.sparingly)
        let names = profile.palette.flattering.prefix(3).map(\.title)
        if names.count == 3 {
            section(String(localized: "Colour proportions"),
                    String(localized: "60-30-10: about 60% of an outfit in \(names[0]), 30% in \(names[1]) and a 10% accent of \(names[2]). Keep your best colours near your face."))
        }
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.care, id: \.self) { line in
                    Label(line, systemImage: "drop.fill").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Washing and care").font(.subheadline.weight(.semibold))
        }
    }

    private func tips(_ title: String, _ list: [StyleAdvice.Tip]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(list, id: \.self) { tip in
                Label(tip.text, systemImage: "circle.fill")
                    .labelStyle(BulletLabel())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static let care = [
        String(localized: "Cotton and denim: 30–40 °C, inside out; wash jeans rarely and dry them on a line to keep the colour."),
        String(localized: "Wool and knitwear: cold hand wash or the wool programme, dry flat; never wring or tumble-dry."),
        String(localized: "Viscose and modal: 30 °C gentle cycle, low spin; they shrink in heat."),
        String(localized: "Linen: 30–40 °C gentle, dry on a hanger, iron while slightly damp."),
        String(localized: "Elastane blends: no tumble dryer; heat ruins the stretch."),
        String(localized: "Wash dark and bright colours apart the first few times, and check the care label."),
    ]

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func swatches(_ colors: [ColorFamily]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(colors, id: \.self) { c in
                    VStack(spacing: 4) {
                        Circle().fill(c.swatch).frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(.secondary.opacity(0.3)))
                        Text(c.title).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// The three questions, with plain ways to tell the answers.
private struct StyleQuestionsView: View {
    @Binding var stored: String
    @Environment(\.dismiss) private var dismiss
    @State private var undertone: StyleProfile.Undertone
    @State private var depth: StyleProfile.SkinDepth
    @State private var vibe: StyleProfile.Vibe
    @State private var occasion: StyleAdvice.Occasion
    @State private var ease: StyleAdvice.Ease
    @State private var scanned: Bool
    @State private var scanning = false

    init(stored: Binding<String>, initial: StyleProfile?) {
        _stored = stored
        _undertone = State(initialValue: initial?.undertone ?? .neutral)
        _depth = State(initialValue: initial?.depth ?? .medium)
        _vibe = State(initialValue: initial?.vibe ?? .casual)
        _occasion = State(initialValue: initial?.occasion ?? .everyday)
        _ease = State(initialValue: initial?.ease ?? .fitted)
        _scanned = State(initialValue: initial?.scanned ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label(scanned ? "Scan my skin tone again" : "Scan my skin tone", systemImage: "camera.viewfinder")
                    }
                } footer: {
                    Text("The front camera reads your skin's depth and undertone in a few seconds, in daylight. Or choose them below.")
                }
                Section {
                    Picker("Skin tone", selection: $depth) {
                        ForEach(StyleProfile.SkinDepth.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Skin tone")
                }
                Section {
                    Picker("Undertone", selection: $undertone) {
                        ForEach(StyleProfile.Undertone.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Undertone")
                } footer: {
                    Text("Look at the veins on your wrist in daylight: greenish means warm, bluish or purple means cool, both means neutral. If gold jewellery suits you better it's warm, silver is cool.")
                }
                Section("Which style do you like?") {
                    Picker("Style", selection: $vibe) {
                        ForEach(StyleProfile.Vibe.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("What do you dress for most?") {
                    Picker("Occasion", selection: $occasion) {
                        ForEach(StyleAdvice.Occasion.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("How do you like clothes to sit?") {
                    Picker("Fit", selection: $ease) {
                        ForEach(StyleAdvice.Ease.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                SkinToneScanView { reading in
                    depth = reading.depth
                    undertone = reading.undertone
                    scanned = true
                }
            }
            .navigationTitle("Your style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let profile = StyleProfile(undertone: undertone, depth: depth, vibe: vibe, occasion: occasion,
                                                   ease: ease, scanned: scanned)
                        stored = (try? JSONEncoder().encode(profile)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        AppSounds.shared.play(.saved)
                        dismiss()
                    }
                }
            }
        }
    }
}

extension StyleProfile.SkinDepth {
    var title: String {
        switch self {
        case .light: String(localized: "Light")
        case .medium: String(localized: "Medium")
        case .tan: String(localized: "Tan")
        case .deep: String(localized: "Deep")
        }
    }
}

extension StyleProfile.Undertone {
    var title: String {
        switch self {
        case .warm: String(localized: "Warm")
        case .cool: String(localized: "Cool")
        case .neutral: String(localized: "Neutral")
        }
    }
}

extension StyleProfile.Vibe {
    var title: String {
        switch self {
        case .classic: String(localized: "Classic and smart")
        case .casual: String(localized: "Casual and sporty")
        case .minimal: String(localized: "Minimal")
        case .bold: String(localized: "Bold and trendy")
        }
    }

    var pieces: String {
        switch self {
        case .classic: String(localized: "Oxford shirts, chinos, a navy blazer, fine knits and leather shoes or loafers.")
        case .casual: String(localized: "Good basic T-shirts, straight jeans, sweatshirts, an overshirt and clean sneakers.")
        case .minimal: String(localized: "Solid colours in neutral tones, clean lines, few but well-fitting pieces; no big logos.")
        case .bold: String(localized: "One statement piece per outfit: a patterned shirt, a strong colour or an unusual cut, with calm basics around it.")
        }
    }
}

extension StyleProfile.ColorSeason {
    var title: String {
        switch self {
        case .spring: String(localized: "Your colours: spring (warm and light)")
        case .summer: String(localized: "Your colours: summer (cool and soft)")
        case .autumn: String(localized: "Your colours: autumn (warm and deep)")
        case .winter: String(localized: "Your colours: winter (cool and clear)")
        }
    }

    var explanation: String {
        switch self {
        case .spring: String(localized: "Warm, fresh colours light up your face: camel, coral, warm green, sky blue.")
        case .summer: String(localized: "Soft, cool colours suit you: navy, grey-blue, lavender, dusty pink.")
        case .autumn: String(localized: "Rich, earthy colours suit you: olive, rust, brown, burgundy, mustard.")
        case .winter: String(localized: "Clear, strong contrasts suit you: black and white, navy, true red, deep purple.")
        }
    }
}

extension BodyShape {
    var title: String {
        switch self {
        case .invertedTriangle: String(localized: "Body shape: inverted triangle")
        case .rectangle: String(localized: "Body shape: rectangle")
        case .hourglass: String(localized: "Body shape: hourglass")
        case .pear: String(localized: "Body shape: pear")
        case .apple: String(localized: "Body shape: apple")
        case .triangle: String(localized: "Body shape: triangle")
        case .oval: String(localized: "Body shape: oval")
        }
    }

    var advice: String {
        switch self {
        case .invertedTriangle: String(localized: "Balance the shoulders: V-necks, straight or relaxed trousers, lighter colours below; skip shoulder padding and horizontal stripes on top.")
        case .rectangle: String(localized: "Add shape with layers (shirt over T-shirt, jacket), structured shoulders and straight or slightly tapered trousers.")
        case .hourglass: String(localized: "Show the waist: wrap and belted pieces, high-waisted trousers, fitted rather than boxy tops.")
        case .pear: String(localized: "Draw the eye up: details and light colours on top, boat or wide necklines, darker A-line or wide-leg bottoms.")
        case .apple: String(localized: "Long vertical lines and flowing fabrics: V-necks, empire waists, open jackets; avoid tight waistbands.")
        case .triangle: String(localized: "Broaden the shoulders: structured jackets, horizontal stripes or details on top, darker straight trousers.")
        case .oval: String(localized: "Long lines: darker single-colour tops, open jackets, straight cuts that skim rather than cling or balloon.")
        }
    }
}

extension StyleAdvice.Occasion {
    var title: String {
        switch self {
        case .work: String(localized: "Work")
        case .everyday: String(localized: "Everyday")
        case .evening: String(localized: "Evenings")
        case .active: String(localized: "Active")
        }
    }
}

extension StyleAdvice.Ease {
    var title: String {
        switch self {
        case .fitted: String(localized: "Fitted")
        case .relaxed: String(localized: "Relaxed")
        }
    }
}

extension StyleAdvice.Tip {
    var text: String {
        switch self {
        case .vNeck: String(localized: "V-necks and open collars lengthen the upper body.")
        case .skimPastWaist: String(localized: "Tops that skim and fall past the waist; no tight waistbands or boxy cropped cuts.")
        case .detailOnTop: String(localized: "Detail, colour and structure on top: boat necks, a structured jacket.")
        case .straightBelow: String(localized: "Straight, A-line or wide legs below, in darker colours.")
        case .softShoulders: String(localized: "V-necks and soft shoulders on top; no shoulder pads or wide stripes across the chest.")
        case .volumeBelow: String(localized: "Some volume or a lighter colour below: straight or relaxed trousers, A-line skirts.")
        case .showWaist: String(localized: "Show the waist: wrap and belted pieces, high waists, fitted rather than boxy.")
        case .createShape: String(localized: "Create shape: layers, a belt or a defined waist, structured shoulders.")
        case .relaxedBalance: String(localized: "Relaxed doesn't mean big: pair one roomy piece with one fitted one.")
        case .fittedNoPull: String(localized: "Fitted means following the body, not pulling: no creases across buttons or seams.")
        case .fluidFabrics: String(localized: "Fluid fabrics that drape: viscose, modal, soft cotton jersey, light wool.")
        case .structuredTopSoftBelow: String(localized: "Structured fabrics on top (cotton twill, poplin, denim), soft drape below.")
        case .softTops: String(localized: "Soft, unstructured tops (jersey, merino), heavier fabrics below.")
        case .stretchDrape: String(localized: "Fabrics with some stretch and drape that follow the shape: jersey, crepe, stretch cotton.")
        case .bodyFabrics: String(localized: "Fabrics with body that hold a shape: cotton twill, denim, wool, structured knits.")
        case .workFabrics: String(localized: "For work: wool and wool blends, cotton poplin, crepe; they keep their shape all day.")
        case .everydayFabrics: String(localized: "Every day: cotton, denim and merino; easy to wash and breathable.")
        case .eveningFabrics: String(localized: "Evenings: one piece with sheen (satin, silk, velvet), the rest matt.")
        case .activeFabrics: String(localized: "Active: technical knits with elastane and quick-drying cotton blends.")
        case .stiffShinyOverMiddle: String(localized: "Stiff or shiny fabrics (satin, taffeta) and thin clingy knits over the middle.")
        case .clingyOverHips: String(localized: "Thin clingy fabrics over the hips and thighs.")
        case .bulkyAcrossShoulders: String(localized: "Stiff, bulky fabrics across the shoulders.")
        case .boxyHidingWaist: String(localized: "Stiff boxy fabrics that hide the waist.")
        case .limpFabrics: String(localized: "Very limp fabrics that hang straight down.")
        }
    }
}

/// A small dot before each tip.
private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 5)).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            configuration.title
        }
    }
}
