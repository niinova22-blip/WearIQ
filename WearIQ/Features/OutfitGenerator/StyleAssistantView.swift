import OutfitRecommendationEngine
import SwiftData
import SwiftUI

struct StyleAssistantView: View {
    @Environment(AppContainer.self) private var container
    @Query private var entries: [WardrobeEntry]
    @State private var occasion: Occasion = .daily
    @State private var season: Season = .current()
    @AppStorage("favoriteColors") private var favoriteColorsRaw = ""
    @AppStorage("avoidedColors") private var avoidedColorsRaw = ""

    private let engine: any OutfitRecommending = RuleBasedOutfitEngine()

    private var preferences: OutfitPreferences {
        OutfitPreferences(favoriteColors: Self.colors(favoriteColorsRaw), avoidedColors: Self.colors(avoidedColorsRaw))
    }

    private var outfits: [Outfit] {
        engine.outfits(from: entries.map(\.item), occasion: occasion, season: season, preferences: preferences, limit: 5)
    }

    var body: some View {
        Group {
            if !container.isPremium {
                PremiumFeaturePlaceholder(
                    title: "Style assistant",
                    detail: "Outfit suggestions from your own wardrobe for daily, work, formal, sport and evening occasions.",
                    symbol: "sparkles")
            } else {
                content
            }
        }
        .navigationTitle("Style")
    }

    private var content: some View {
        List {
            Section {
                Picker("Occasion", selection: $occasion) {
                    ForEach(Occasion.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Season", selection: $season) {
                    ForEach(Season.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                NavigationLink("Colour preferences") {
                    ColorPreferencesView(favoriteRaw: $favoriteColorsRaw, avoidedRaw: $avoidedColorsRaw)
                }
            }
            let suggestions = outfits
            if suggestions.isEmpty {
                Section {
                    Text("No outfit fits this occasion and season yet. Add at least one top and one bottom (or a dress) tagged with a matching style and season.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, outfit in
                    Section {
                        ForEach(outfit.items) { item in
                            if let entry = entries.first(where: { $0.id == item.id }) {
                                WardrobeRow(entry: entry)
                            }
                        }
                        Text(outfit.reasons.compactMap(\.text).joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        HStack {
                            Text("Outfit \(index + 1)")
                            Spacer()
                            Text("\(Int((outfit.score * 100).rounded()))%")
                                .accessibilityLabel(Text("Match \(Int((outfit.score * 100).rounded())) percent"))
                        }
                    }
                }
            }
        }
    }

    static func colors(_ raw: String) -> Set<ColorFamily> {
        Set(raw.split(separator: ",").compactMap { ColorFamily(rawValue: String($0)) })
    }
}

private struct ColorPreferencesView: View {
    @Binding var favoriteRaw: String
    @Binding var avoidedRaw: String

    var body: some View {
        List {
            Section("Colours I like") { toggles($favoriteRaw) }
            Section("Colours I avoid") { toggles($avoidedRaw) }
        }
        .navigationTitle("Colour preferences")
    }

    private func toggles(_ raw: Binding<String>) -> some View {
        ForEach(ColorFamily.allCases, id: \.self) { c in
            Toggle(isOn: Binding(
                get: { StyleAssistantView.colors(raw.wrappedValue).contains(c) },
                set: { on in
                    var set = StyleAssistantView.colors(raw.wrappedValue)
                    if on { set.insert(c) } else { set.remove(c) }
                    raw.wrappedValue = set.map(\.rawValue).sorted().joined(separator: ",")
                })) {
                Label { Text(c.title) } icon: { Circle().fill(c.swatch).frame(width: 14, height: 14) }
            }
        }
    }
}

extension Outfit.Reason {
    var text: String? {
        switch self {
        case .suitsOccasion: String(localized: "Suits the occasion")
        case .neutralBase: String(localized: "Balanced colours")
        case let .harmoniousColors(a, b): String(localized: "\(a.title) and \(b.title) go well together")
        case let .favoriteColor(c): String(localized: "Includes \(c.title.lowercased()), a colour you like")
        case .seasonAppropriate: nil
        case .goodFit: String(localized: "Pieces that fit you well")
        case .layeredForCold: String(localized: "Layered for the weather")
        }
    }
}
