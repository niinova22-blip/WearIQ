import FitEngine
import Foundation
import OutfitRecommendationEngine
import ProductMeasurementParser
import ShoppingAssistant
import SwiftData
import SwiftUI
import WearIQCore

/// The smart shopping memory on the app's side: what the Safari extension needs (the
/// user's body and style), and filing what it saw while the user browsed.
@MainActor
enum ShoppingMemory {
    /// Leaves the user's own latest body and confirmed style for the extension.
    static func publishShopper(_ context: ModelContext) {
        let descriptor = FetchDescriptor<StoredBodyProfile>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let body = (try? context.fetch(descriptor))?.of(nil).first?.profile else {
            ShoppingBridge.saveShopper(nil)
            return
        }
        let style = LearnedStyle.current.flatMap { $0.style.confirmed ? $0.style : nil }
        let preference = UserDefaults.standard.string(forKey: "fitPreference").flatMap(FitPreference.init(rawValue:))
        ShoppingBridge.saveShopper(ShoppingAssistant.Shopper(body: body, style: style, region: SizeRegionSetting.current,
                                                             preference: preference))
    }

    /// Files the products the extension saw as checks, sized for the user's body as it is
    /// now. A page seen again updates its entry; the user's own checks aren't replaced.
    @discardableResult
    static func importInbox(_ context: ModelContext, engine: any FitAnalyzing = FitEngine()) -> Int {
        let entries = ShoppingBridge.inbox()
        guard !entries.isEmpty else { return 0 }
        let descriptor = FetchDescriptor<StoredBodyProfile>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let body = (try? context.fetch(descriptor))?.of(nil).first?.profile
        var filed = 0
        for (account, entry) in entries {
            defer { ShoppingBridge.remove(account: account) }
            let info = ShoppingAssistant.product(entry.page)
            let audience: GarmentAudience? = body?.sex.map { $0 == .female ? .women : .men }
            guard let body, let (spec, _) = ProductSpec.make(from: info, fallbackAudience: audience,
                                                                     region: SizeRegionSetting.current) else { continue }
            let key = info.productKey ?? "url:" + entry.page.url
            let existing = (try? context.fetch(FetchDescriptor<SavedAnalysis>(predicate: #Predicate { $0.productKey == key }))) ?? []
            if existing.contains(where: { $0.fromSafari != true }) { continue }
            existing.forEach(context.delete)
            // The way the user likes clothes to sit (Profile → Measurement changes), as in their own checks.
            let preference = UserDefaults.standard.string(forKey: "fitPreference").flatMap(FitPreference.init(rawValue:)) ?? .asDesigned
            let analysis = engine.analyze(body: body, garment: spec, preference: preference)
            guard let saved = try? SavedAnalysis(productKey: key, productName: info.name, brand: info.brand,
                                                 imageURL: info.imageURL, pageURL: info.pageURL ?? URL(string: entry.page.url),
                                                 spec: spec, analysis: analysis, material: info.material,
                                                 createdAt: entry.seenAt) else { continue }
            saved.fromSafari = true
            context.insert(saved)
            filed += 1
        }
        try? context.save()
        return filed
    }

    /// What the user keeps looking at: brands, colours and kinds of garment, most first.
    struct Taste: Equatable {
        var brands: [String] = []
        var colors: [ColorFamily] = []
        var kinds: [GarmentCategory] = []
    }

    static func taste(of analyses: [SavedAnalysis]) -> Taste {
        func top<T: Hashable>(_ values: [T], _ n: Int) -> [T] {
            Dictionary(grouping: values, by: { $0 }).sorted { $0.value.count > $1.value.count }.prefix(n).map(\.key)
        }
        return Taste(brands: top(analyses.compactMap(\.brand), 3),
                     colors: top(analyses.compactMap { ColorFamily.named(in: $0.productName ?? "") }, 3),
                     kinds: top(analyses.compactMap { $0.spec?.category }, 3))
    }
}

/// "Seen in Safari": every garment the extension sized, grouped by kind so they compare
/// at a glance, under what the user's browsing says about their taste.
struct ShoppingMemoryView: View {
    @Query(filter: #Predicate<SavedAnalysis> { $0.fromSafari == true }, sort: \SavedAnalysis.createdAt, order: .reverse)
    private var seen: [SavedAnalysis]

    var body: some View {
        List {
            if seen.isEmpty {
                SafariSetupSection()
            } else {
                let taste = ShoppingMemory.taste(of: seen)
                Section {
                    if !taste.brands.isEmpty { LabeledContent("Brands", value: taste.brands.joined(separator: ", ")) }
                    if !taste.colors.isEmpty { LabeledContent("Colours", value: taste.colors.map(\.title).joined(separator: ", ")) }
                    if !taste.kinds.isEmpty { LabeledContent("Kinds", value: taste.kinds.map(\.title).joined(separator: ", ")) }
                } header: {
                    Text("What you keep looking at")
                }
                let kinds = Array(Set(seen.compactMap { $0.spec?.category })).sorted { $0.rawValue < $1.rawValue }
                ForEach(kinds, id: \.self) { kind in
                    Section(kind.title) {
                        // Best fit first: the size the engine is surest of.
                        ForEach(seen.filter { $0.spec?.category == kind }.sorted(by: Self.betterFit)) { saved in
                            NavigationLink { FitResultView(saved: saved) } label: { ShoppingRow(saved: saved) }
                        }
                    }
                }
                SafariSetupSection()
            }
        }
        .navigationTitle("Shopping memory")
    }

    static func betterFit(_ a: SavedAnalysis, _ b: SavedAnalysis) -> Bool {
        func score(_ s: SavedAnalysis) -> Int {
            guard let analysis = s.analysis else { return 0 }
            return 3 - ReturnRisk.assess(analysis, category: s.spec?.category, productName: s.productName).level.rank
        }
        return score(a) > score(b)
    }
}

extension ReturnRisk.Level {
    var rank: Int { ReturnRisk.Level.allCases.firstIndex(of: self) ?? 0 }
}

struct ShoppingRow: View {
    let saved: SavedAnalysis

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AsyncImage(url: saved.imageURL) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "tshirt") }
                .frame(width: 44, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                if let brand = saved.brand { Text(brand).font(.caption).foregroundStyle(.secondary) }
                Text(saved.productName ?? String(localized: "Garment")).font(.subheadline).lineLimit(2)
            }
            Spacer()
            if let analysis = saved.analysis {
                let risk = ReturnRisk.assess(analysis, category: saved.spec?.category, productName: saved.productName)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(analysis.recommendedSize?.label ?? "–").font(.headline)
                    Image(systemName: risk.level.symbol).foregroundStyle(risk.level.color).font(.caption)
                }
            }
        }
    }
}

/// How to turn the Safari extension on (Safari's own settings; no app can do it).
struct SafariSetupSection: View {
    var body: some View {
        Section {
            Label("Settings → Apps → Safari → Extensions → WearIQ: turn it on.", systemImage: "1.circle.fill")
            Label("On a clothing store's page, tap the page menu (aA or the puzzle piece) → WearIQ → Always Allow on Every Website, or on the stores you choose.", systemImage: "2.circle.fill")
            Label("Browse as usual: your size shows on every garment page, and what you looked at is here when you open WearIQ.", systemImage: "3.circle.fill")
        } header: {
            Text("Safari extension")
        } footer: {
            Text("Only clothing pages of the stores you allow are read, on this iPhone; nothing you type, no accounts, nothing sent anywhere.")
        }
    }
}

/// The home screen's way in: how many garments were seen in Safari, or how to start.
struct ShoppingMemoryCard: View {
    @Query(filter: #Predicate<SavedAnalysis> { $0.fromSafari == true }) private var seen: [SavedAnalysis]

    var body: some View {
        NavigationLink {
            ShoppingMemoryView()
        } label: {
            Card {
                Label("Shopping memory", systemImage: "safari.fill").font(.headline)
                Text(seen.isEmpty
                     ? String(localized: "Turn on the Safari extension: your size on every clothing page, and everything you looked at, here.")
                     : String(localized: "\(seen.count) garments from your browsing, sized for you."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .buttonStyle(.plain)
    }
}
