import OutfitRecommendationEngine
import SwiftData
import SwiftUI

struct WardrobeView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WardrobeEntry.createdAt, order: .reverse) private var entries: [WardrobeEntry]
    @State private var categoryFilter: WardrobeCategory?
    @State private var seasonFilter: Season?
    @State private var editing: WardrobeEntry?
    @State private var adding = false

    private var filtered: [WardrobeEntry] {
        entries.filter { e in
            (categoryFilter == nil || e.category == categoryFilter)
                && (seasonFilter.map { e.seasons.contains($0) } ?? true)
        }
    }

    var body: some View {
        Group {
            if !container.isPremium {
                PremiumFeaturePlaceholder(
                    title: "Digital wardrobe",
                    detail: "Keep your clothes with category, colour, size, fit, season and photo, and filter them anytime.",
                    symbol: "tshirt")
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("Your wardrobe is empty", systemImage: "tshirt")
                } description: {
                    Text("Add the clothes you own to get outfit suggestions.")
                } actions: {
                    Button("Add item") { adding = true }.buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
        .navigationTitle("Wardrobe")
        .toolbar {
            if container.isPremium {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(Text("Add item"))
                }
            }
        }
        .sheet(isPresented: $adding) { WardrobeItemEditor() }
        .sheet(item: $editing) { WardrobeItemEditor(existing: $0) }
    }

    private var list: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        FilterChip(title: String(localized: "All"), selected: categoryFilter == nil) { categoryFilter = nil }
                        ForEach(WardrobeCategory.allCases, id: \.self) { c in
                            FilterChip(title: c.title, selected: categoryFilter == c) { categoryFilter = c }
                        }
                    }
                }
                Picker("Season", selection: $seasonFilter) {
                    Text("All seasons").tag(Season?.none)
                    ForEach(Season.allCases, id: \.self) { Text($0.title).tag(Season?.some($0)) }
                }
            }
            Section {
                ForEach(filtered) { entry in
                    Button { editing = entry } label: { WardrobeRow(entry: entry) }
                        .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    let items = filtered
                    offsets.map { items[$0] }.forEach(modelContext.delete)
                    try? modelContext.save()
                }
            } footer: {
                Text("\(filtered.count) items")
            }
        }
    }
}

struct WardrobeRow: View {
    let entry: WardrobeEntry

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Group {
                if let data = entry.photo, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    entry.color.swatch.overlay(Image(systemName: entry.category.symbol).foregroundStyle(.white.opacity(0.8)))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.headline)
                Text([entry.brand, entry.size, entry.color.title].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.accentColor : Theme.screenBackground, in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct PremiumFeaturePlaceholder: View {
    @State private var showPaywall = false
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbol: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            Button {
                showPaywall = true
            } label: {
                Label("Unlock with Premium", systemImage: "crown.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .background(Theme.screenBackground)
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }
}

// MARK: - Display names

extension WardrobeCategory {
    var title: String {
        switch self {
        case .top: String(localized: "Tops")
        case .bottom: String(localized: "Bottoms")
        case .dress: String(localized: "Dresses")
        case .outerwear: String(localized: "Outerwear")
        case .shoes: String(localized: "Shoes")
        case .accessory: String(localized: "Accessories")
        }
    }

    var symbol: String {
        switch self {
        case .top: "tshirt"
        case .bottom: "rectangle.portrait"
        case .dress: "figure.dress.line.vertical.figure"
        case .outerwear: "jacket"
        case .shoes: "shoe"
        case .accessory: "eyeglasses"
        }
    }
}

extension ColorFamily {
    var title: String {
        switch self {
        case .black: String(localized: "Black")
        case .white: String(localized: "White")
        case .gray: String(localized: "Grey")
        case .navy: String(localized: "Navy")
        case .beige: String(localized: "Beige")
        case .brown: String(localized: "Brown")
        case .denim: String(localized: "Denim")
        case .blue: String(localized: "Blue")
        case .green: String(localized: "Green")
        case .olive: String(localized: "Olive")
        case .red: String(localized: "Red")
        case .burgundy: String(localized: "Burgundy")
        case .pink: String(localized: "Pink")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .purple: String(localized: "Purple")
        case .multicolor: String(localized: "Multicolour")
        }
    }

    var swatch: Color {
        switch self {
        case .black: .black
        case .white: Color(white: 0.95)
        case .gray: .gray
        case .navy: Color(red: 0.1, green: 0.15, blue: 0.35)
        case .beige: Color(red: 0.86, green: 0.78, blue: 0.64)
        case .brown: .brown
        case .denim: Color(red: 0.3, green: 0.45, blue: 0.65)
        case .blue: .blue
        case .green: .green
        case .olive: Color(red: 0.42, green: 0.45, blue: 0.2)
        case .red: .red
        case .burgundy: Color(red: 0.5, green: 0.1, blue: 0.18)
        case .pink: .pink
        case .orange: .orange
        case .yellow: .yellow
        case .purple: .purple
        case .multicolor: .indigo
        }
    }
}

extension Season {
    var title: String {
        switch self {
        case .spring: String(localized: "Spring")
        case .summer: String(localized: "Summer")
        case .autumn: String(localized: "Autumn")
        case .winter: String(localized: "Winter")
        }
    }

    /// Northern-hemisphere season for a date.
    static func current(_ date: Date = Date(), calendar: Calendar = .current) -> Season {
        switch calendar.component(.month, from: date) {
        case 3...5: .spring
        case 6...8: .summer
        case 9...11: .autumn
        default: .winter
        }
    }
}

extension StyleTag {
    var title: String {
        switch self {
        case .casual: String(localized: "Casual")
        case .smartCasual: String(localized: "Smart casual")
        case .business: String(localized: "Business")
        case .formal: String(localized: "Formal")
        case .sporty: String(localized: "Sporty")
        case .evening: String(localized: "Evening")
        }
    }
}

extension Occasion {
    var title: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .work: String(localized: "Work")
        case .formal: String(localized: "Formal")
        case .sport: String(localized: "Sport")
        case .evening: String(localized: "Evening")
        case .specialEvent: String(localized: "Special event")
        }
    }
}
