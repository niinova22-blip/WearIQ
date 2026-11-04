import AppIntents
import FitEngine
import Foundation
import SwiftData
import WearIQCore
#if canImport(VisualIntelligence)
import VisualIntelligence
#endif

/// Siri, Shortcuts, Spotlight and (iOS 26) visual intelligence. The intents run in the
/// app's process and reach its data through the container set at launch.
@MainActor
enum AppShortcuts {
    static var container: AppContainer?
}

// MARK: Checked garments as entities

/// A garment checked in WearIQ, as Siri, Spotlight and visual intelligence show it.
struct CheckedGarmentEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Checked garment")
    }

    static var defaultQuery = CheckedGarmentQuery()

    var id: String
    var name: String
    var size: String?
    var imageURL: URL?

    var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource = size.map { LocalizedStringResource("Your size: \($0)") }
            ?? LocalizedStringResource("No size found")
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle,
                                     image: imageURL.map { DisplayRepresentation.Image(url: $0) })
    }

    init(_ saved: SavedAnalysis) {
        id = saved.productKey
        name = saved.productName ?? String(localized: "Garment")
        size = saved.analysis?.recommendedSize?.label
        imageURL = saved.imageURL
    }
}

struct CheckedGarmentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CheckedGarmentEntity] {
        await MainActor.run { Self.saved().filter { identifiers.contains($0.productKey) }.map(CheckedGarmentEntity.init) }
    }

    func suggestedEntities() async throws -> [CheckedGarmentEntity] {
        await MainActor.run { Self.saved().prefix(10).map(CheckedGarmentEntity.init) }
    }

    /// The active person's checks, newest first.
    @MainActor
    static func saved() -> [SavedAnalysis] {
        guard let container = AppShortcuts.container else { return [] }
        let descriptor = FetchDescriptor<SavedAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        let person = container.activePersonID
        return ((try? container.modelContainer.mainContext.fetch(descriptor)) ?? []).filter { $0.personID == person }
    }
}

/// Opens a checked garment's result.
struct OpenCheckedGarmentIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open checked garment"

    @Parameter(title: "Garment")
    var target: CheckedGarmentEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppShortcuts.container?.pendingAnalysisKey = target.id
        return .result()
    }
}

// MARK: Actions

/// "Check my size in WearIQ": a product link, checked against the active body.
struct CheckProductSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "Check my size"
    static let description = IntentDescription("Checks which size of a garment fits you, from its product page link.")
    static let openAppWhenRun = true

    @Parameter(title: "Product link")
    var link: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        AppShortcuts.container?.pendingProductLink = link
        return .result()
    }
}

/// "What size am I in Zara?": from the purchases the user told WearIQ about.
struct BrandSizeIntent: AppIntent {
    static let title: LocalizedStringResource = "My size in a brand"
    static let description = IntentDescription("Tells the size you last took in a brand and how it fit.")

    @Parameter(title: "Brand")
    var brand: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = AppShortcuts.container else { return .result(dialog: "Open WearIQ once first.") }
        let records = (try? container.modelContainer.mainContext.fetch(FetchDescriptor<PurchaseRecord>())) ?? []
        let mine = records.filter { $0.personID == container.activePersonID }
        let memory = BrandMemory(records: mine)
        guard let latest = memory.relevant(brand: brand, category: nil).max(by: { $0.createdAt < $1.createdAt }) else {
            return .result(dialog: "No purchases from \(brand) yet. Check a garment from \(brand) in WearIQ and tell it how it fit.")
        }
        return .result(dialog: "You took \(latest.size) in \(latest.brand) and it was \(latest.feel.title.lowercased()).")
    }
}

struct WearIQShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CheckProductSizeIntent(),
                    phrases: ["Check my size in \(.applicationName)", "Will it fit with \(.applicationName)"],
                    shortTitle: "Check my size", systemImageName: "tshirt")
        AppShortcut(intent: BrandSizeIntent(),
                    phrases: ["My brand size in \(.applicationName)", "What size am I in \(.applicationName)"],
                    shortTitle: "My size in a brand", systemImageName: "tag")
    }
}

// MARK: Visual intelligence (iOS 26)

#if canImport(VisualIntelligence)
/// Circle a jacket on screen or point the camera at one: the garments of that kind the
/// user checked in WearIQ, with their sizes. Matching is by the labels visual
/// intelligence gives (it says "jacket", not the brand); no image leaves the phone.
@available(iOS 26.0, *)
struct GarmentVisualSearchQuery: IntentValueQuery {
    func values(for input: SemanticContentDescriptor) async throws -> [CheckedGarmentEntity] {
        let labels = input.labels
        let categories = Set(labels.compactMap(Self.category(for:)))
        let clothing = labels.contains { ["clothing", "apparel", "garment", "outfit", "fashion"].contains($0.lowercased()) }
        guard !categories.isEmpty || clothing else { return [] }
        return await MainActor.run {
            CheckedGarmentQuery.saved().filter { s in
                categories.isEmpty || s.spec.map { categories.contains($0.category) } ?? false
            }
            .prefix(12).map(CheckedGarmentEntity.init)
        }
    }

    /// The garment kind a visual label names.
    static func category(for label: String) -> GarmentCategory? {
        let l = label.lowercased()
        let table: [(String, GarmentCategory)] = [
            ("t-shirt", .tshirt), ("tshirt", .tshirt), ("tee", .tshirt), ("shirt", .shirt), ("blouse", .shirt),
            ("jacket", .jacket), ("blazer", .jacket), ("coat", .coat), ("parka", .coat), ("trench", .coat),
            ("jeans", .pants), ("trousers", .pants), ("pants", .pants), ("leggings", .pants),
            ("shorts", .shorts), ("skirt", .skirt), ("dress", .dress), ("gown", .dress),
            ("sweater", .sweater), ("hoodie", .sweater), ("sweatshirt", .sweater), ("cardigan", .sweater), ("jumper", .sweater),
        ]
        return table.first { l.contains($0.0) }?.1
    }
}
#endif
