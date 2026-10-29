import OutfitRecommendationEngine
import SwiftData
import SwiftUI

/// Outfit ideas from the user's own wardrobe: an outfit of the day, more ideas,
/// saved outfits and the pieces that would unlock the most new combinations.
struct StyleAssistantView: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \WardrobeEntry.createdAt, order: .reverse) private var entries: [WardrobeEntry]
    @State private var occasion: Occasion = .daily
    @State private var season: Season = .current()
    @State private var featuredIndex = 0
    @AppStorage("favoriteColors") private var favoriteColorsRaw = ""
    @AppStorage("avoidedColors") private var avoidedColorsRaw = ""
    /// Saved outfits, one per line, item ids comma-separated.
    @AppStorage("savedOutfits") private var savedOutfitsRaw = ""

    private let engine: any OutfitRecommending = RuleBasedOutfitEngine()

    private var preferences: OutfitPreferences {
        OutfitPreferences(favoriteColors: Self.colors(favoriteColorsRaw), avoidedColors: Self.colors(avoidedColorsRaw))
    }

    private func outfits(_ items: [WardrobeItem], limit: Int = 20) -> [Outfit] {
        engine.outfits(from: items, occasion: occasion, season: season, preferences: preferences, limit: limit)
    }

    var body: some View {
        Group {
            if !container.isPremium {
                ScrollView {
                    VStack(spacing: Theme.Spacing.l) {
                        StyleProfileCard()
                        PremiumFeaturePlaceholder(
                            title: "Style assistant",
                            detail: "Outfit suggestions from your own wardrobe for daily, work, formal, sport and evening occasions.",
                            symbol: "sparkles")
                    }
                    .padding(.vertical, Theme.Spacing.m)
                }
                .background(Theme.screenBackground)
            } else {
                content
            }
        }
        .navigationTitle("Style")
        .toolbar {
            if container.isPremium {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Season", selection: $season) {
                            ForEach(Season.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        NavigationLink("Colour preferences") {
                            ColorPreferencesView(favoriteRaw: $favoriteColorsRaw, avoidedRaw: $avoidedColorsRaw)
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("Season and colours"))
                }
            }
        }
    }

    private var content: some View {
        let all = outfits(entries.map(\.item))
        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                StyleProfileCard()
                occasionChips
                if all.isEmpty {
                    emptyState
                } else {
                    featured(all[featuredIndex % all.count], total: all.count)
                    if all.count > 1 { moreIdeas(all) }
                }
                savedSection
                gapsSection(baseCount: all.count)
            }
            .padding(.vertical, Theme.Spacing.m)
        }
        .background(Theme.screenBackground)
        .onChange(of: occasion) { featuredIndex = 0 }
        .onChange(of: season) { featuredIndex = 0 }
    }

    // MARK: Sections

    private var occasionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                ForEach(Occasion.allCases, id: \.self) { o in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { occasion = o }
                    } label: {
                        Text(o.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .foregroundStyle(occasion == o ? .white : .primary)
                            .background {
                                Capsule().fill(occasion == o ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.cardBackground))
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
        }
        .sensoryFeedback(.selection, trigger: occasion)
    }

    private func featured(_ outfit: Outfit, total: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Outfit of the day").font(.title3.bold())
                    Text("\(occasion.title) · \(season.title)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                ScoreBadge(score: outfit.score)
            }
            OutfitCollage(items: outfit.items, entries: entries, height: 220)
            let reasons = outfit.reasons.compactMap(\.text)
            if !reasons.isEmpty {
                FlowTags(tags: reasons)
            }
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { featuredIndex += 1 }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.primary)
                .disabled(total < 2)
                Button { toggleSaved(outfit) } label: {
                    Image(systemName: isSaved(outfit) ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(isSaved(outfit) ? .pink : .secondary)
                        .frame(width: 54, height: 54)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .medium), trigger: isSaved(outfit))
                .accessibilityLabel(isSaved(outfit) ? Text("Remove from saved") : Text("Save outfit"))
            }
        }
        .padding(Theme.Spacing.l)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, Theme.Spacing.m)
        .id(featuredIndex)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
    }

    private func moreIdeas(_ all: [Outfit]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("More ideas").font(.headline).padding(.horizontal, Theme.Spacing.m)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.m) {
                    ForEach(Array(all.enumerated()), id: \.offset) { index, outfit in
                        if index != featuredIndex % all.count {
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { featuredIndex = index }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    OutfitCollage(items: outfit.items, entries: entries, height: 130)
                                    ScoreBadge(score: outfit.score)
                                }
                                .frame(width: 170)
                                .padding(10)
                                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.m)
            }
        }
    }

    @ViewBuilder
    private var savedSection: some View {
        let saved = savedOutfits
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Saved outfits").font(.headline).padding(.horizontal, Theme.Spacing.m)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.m) {
                        ForEach(saved, id: \.self) { ids in
                            OutfitCollage(items: entries.filter { ids.contains($0.id) }.map(\.item), entries: entries, height: 110)
                                .frame(width: 140)
                                .padding(8)
                                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .contextMenu {
                                    Button("Remove", systemImage: "trash", role: .destructive) { remove(ids) }
                                }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.m)
                }
            }
        }
    }

    /// Pieces that would unlock the most new outfits, found by actually re-running the
    /// engine with each candidate added to the wardrobe.
    @ViewBuilder
    private func gapsSection(baseCount: Int) -> some View {
        let gaps = suggestedPieces(baseCount: baseCount)
        if !gaps.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Pieces that would add the most").font(.headline)
                ForEach(gaps, id: \.name) { gap in
                    HStack(spacing: Theme.Spacing.m) {
                        gap.color.swatch
                            .overlay(Image(systemName: gap.category.symbol).foregroundStyle(.white.opacity(0.85)))
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Text(gap.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text("+\(gap.gain)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.tint)
                            .accessibilityLabel(Text("\(gap.gain) more outfits"))
                    }
                }
            }
            .padding(Theme.Spacing.l)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.horizontal, Theme.Spacing.m)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accentGradient)
            Text("No outfit for this yet").font(.title3.bold())
            Text("Add at least a top and a bottom (or a dress) that suit this occasion and season.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, Theme.Spacing.m)
    }

    // MARK: Suggestions

    private struct Gap {
        let name: String
        let category: WardrobeCategory
        let color: ColorFamily
        let gain: Int
    }

    private func suggestedPieces(baseCount: Int) -> [Gap] {
        let candidates: [(String, WardrobeCategory, ColorFamily)] = [
            (String(localized: "White shirt or tee"), .top, .white),
            (String(localized: "Navy top"), .top, .navy),
            (String(localized: "Beige trousers"), .bottom, .beige),
            (String(localized: "Dark jeans"), .bottom, .denim),
            (String(localized: "Black trousers"), .bottom, .black),
            (String(localized: "Navy jacket"), .outerwear, .navy),
            (String(localized: "White sneakers"), .shoes, .white),
            (String(localized: "Brown shoes"), .shoes, .brown),
        ]
        let items = entries.map(\.item)
        let styles = occasion.suitedStyles
        return candidates.compactMap { name, category, color in
            let piece = WardrobeItem(name: name, category: category, color: color, seasons: [season], styles: styles)
            let gain = outfits(items + [piece], limit: 40).count - min(baseCount, 40)
            return gain > 0 ? Gap(name: name, category: category, color: color, gain: gain) : nil
        }
        .sorted { $0.gain > $1.gain }
        .prefix(3)
        .map { $0 }
    }

    // MARK: Saved outfits

    private var savedOutfits: [Set<UUID>] {
        savedOutfitsRaw.split(separator: "\n").map { line in
            Set(line.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        }.filter { !$0.isEmpty }
    }

    private func key(_ ids: Set<UUID>) -> String { ids.map(\.uuidString).sorted().joined(separator: ",") }

    private func isSaved(_ outfit: Outfit) -> Bool {
        savedOutfits.contains(Set(outfit.items.map(\.id)))
    }

    private func toggleSaved(_ outfit: Outfit) {
        let ids = Set(outfit.items.map(\.id))
        if isSaved(outfit) { remove(ids) } else {
            savedOutfitsRaw = (savedOutfits.map(key) + [key(ids)]).joined(separator: "\n")
        }
    }

    private func remove(_ ids: Set<UUID>) {
        savedOutfitsRaw = savedOutfits.filter { $0 != ids }.map(key).joined(separator: "\n")
    }

    static func colors(_ raw: String) -> Set<ColorFamily> {
        Set(raw.split(separator: ",").compactMap { ColorFamily(rawValue: String($0)) })
    }
}

/// The pieces of an outfit side by side: product photos where we have them, colour
/// swatches with the category symbol otherwise.
private struct OutfitCollage: View {
    let items: [WardrobeItem]
    let entries: [WardrobeEntry]
    let height: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items) { item in
                let entry = entries.first { $0.id == item.id }
                Group {
                    if let data = entry?.photo, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        item.color.swatch.overlay {
                            VStack(spacing: 4) {
                                Image(systemName: item.category.symbol).font(.title2)
                                Text(item.name).font(.caption2.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(items.map(\.name).joined(separator: ", ")))
    }
}

private struct ScoreBadge: View {
    let score: Double

    var body: some View {
        Text("\(Int((score * 100).rounded()))% match")
            .font(.caption.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(Theme.accentGradient, in: Capsule())
    }
}

private struct FlowTags: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
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
