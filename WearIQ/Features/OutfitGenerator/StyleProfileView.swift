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
        guard let body = profiles.first?.profile, let chest = body[.chest]?.cm, let waist = body[.waist]?.cm,
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
            } else {
                Label("Find your colours and cuts", systemImage: "paintpalette.fill").font(.headline)
                Text("Three quick questions about your skin tone and style. With your measurements, WearIQ suggests the colours, cuts and pieces that suit you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Start") { editing = true }
                    .buttonStyle(.primary)
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .sheet(isPresented: $editing) { StyleQuestionsView(stored: $stored, initial: profile) }
    }

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

    init(stored: Binding<String>, initial: StyleProfile?) {
        _stored = stored
        _undertone = State(initialValue: initial?.undertone ?? .neutral)
        _depth = State(initialValue: initial?.depth ?? .medium)
        _vibe = State(initialValue: initial?.vibe ?? .casual)
    }

    var body: some View {
        NavigationStack {
            Form {
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
                Section("Your style") {
                    Picker("Style", selection: $vibe) {
                        ForEach(StyleProfile.Vibe.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Your style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let profile = StyleProfile(undertone: undertone, depth: depth, vibe: vibe)
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
