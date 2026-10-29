import FitEngine
import OutfitRecommendationEngine
import SwiftData
import SwiftUI
import WearIQCore

/// "You bought M from this brand and it was tight; consider one size up."
struct BrandNoteView: View {
    let brand: String?
    let category: GarmentCategory?
    let recommended: String?
    @Query private var records: [PurchaseRecord]

    var body: some View {
        if let note = BrandMemory(records: records).note(brand: brand, category: category, recommended: recommended) {
            Label(note, systemImage: "bookmark.fill")
                .font(.subheadline)
                .padding(Theme.Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        }
    }
}

/// Asks, once the user has the garment, which size they took and how it fit; that is
/// what the brand memory learns from.
struct PurchaseFeedbackCard: View {
    let brand: String?
    let productName: String?
    let category: GarmentCategory?
    let sizes: [String]
    @State var size: String
    @Environment(\.modelContext) private var modelContext
    @State private var saved: PurchaseRecord.Feel?

    var body: some View {
        if let brand, !brand.isEmpty {
            Card {
                Label("Bought it? Tell us how it fit", systemImage: "bag")
                    .font(.headline)
                Text("WearIQ remembers how \(brand) fits you and adjusts future advice for this brand.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("Size you took", selection: $size) {
                    ForEach(sizes, id: \.self) { Text($0).tag($0) }
                }
                if let saved {
                    Label("Saved: \(size), \(saved.title)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    HStack {
                        ForEach(PurchaseRecord.Feel.allCases, id: \.self) { feel in
                            Button(feel.title) { save(feel, brand: brand) }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private func save(_ feel: PurchaseRecord.Feel, brand: String) {
        modelContext.insert(PurchaseRecord(brand: brand, productName: productName, category: category, size: size, feel: feel))
        try? modelContext.save()
        saved = feel
    }
}

extension PurchaseRecord.Feel {
    var title: String {
        switch self {
        case .tight: String(localized: "Tight")
        case .right: String(localized: "Just right")
        case .loose: String(localized: "Loose")
        }
    }
}

/// Compares this size with garments from the wardrobe the user entered measurements for:
/// "2 cm wider in the chest than your Levi's shirt". Only for charts that list the
/// garment's own measurements, since that is what was measured on the wardrobe item.
struct WardrobeComparisonCard: View {
    let category: GarmentCategory?
    let spec: GarmentSpec?
    let sizeLabel: String?
    @Query(sort: \WardrobeEntry.createdAt, order: .reverse) private var wardrobe: [WardrobeEntry]

    var body: some View {
        if let category, let spec, spec.chartKind == .garment,
           let size = spec.sizes.first(where: { $0.label == sizeLabel }) {
            let matches = wardrobe.filter { $0.category == WardrobeCategory(category) && !$0.measurements.isEmpty }
            let rows = matches.prefix(2).compactMap { entry -> (WardrobeEntry, [(GarmentDimension, Double)])? in
                let diffs = GarmentDimension.allCases.compactMap { d -> (GarmentDimension, Double)? in
                    guard let mine = entry.measurements[d], let theirs = size.values[d]?.cm else { return nil }
                    return (d, theirs - mine)
                }
                return diffs.isEmpty ? nil : (entry, diffs)
            }
            if !rows.isEmpty {
                Card {
                    Label("Compared with your own clothes", systemImage: "tshirt")
                        .font(.headline)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.0.name).font(.subheadline.weight(.semibold))
                            Text(row.1.map { Self.describe($0.0, $0.1) }.joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    static func describe(_ d: GarmentDimension, _ delta: Double) -> String {
        let cm = Int(abs(delta).rounded())
        let name = d.title.lowercased()
        if cm == 0 { return String(localized: "\(name) the same") }
        let isLength = [GarmentDimension.bodyLength, .sleeveLength, .inseam, .outseam].contains(d)
        if isLength {
            return delta > 0 ? String(localized: "\(name) \(cm) cm longer") : String(localized: "\(name) \(cm) cm shorter")
        }
        return delta > 0 ? String(localized: "\(name) \(cm) cm wider") : String(localized: "\(name) \(cm) cm narrower")
    }
}

/// Follows the product for a price drop or the chosen size coming back.
struct TrackProductButton: View {
    let pageURL: URL?
    let productName: String?
    let imageURL: URL?
    let size: String?
    @Environment(\.modelContext) private var modelContext
    @Query private var tracked: [TrackedProduct]

    private var isTracked: Bool { tracked.contains { $0.pageURLString == pageURL?.absoluteString && $0.size == size } }

    var body: some View {
        if let pageURL {
            Button {
                Task {
                    let product = TrackedProduct(pageURL: pageURL, productName: productName, imageURL: imageURL, size: size)
                    await ProductTracker.track(product, in: modelContext)
                    await ProductTracker.refreshAll(in: modelContext)
                }
            } label: {
                Label(isTracked
                      ? String(localized: "Following price and size \(size ?? "")")
                      : String(localized: "Tell me when the price drops or \(size ?? "my size") is back"),
                      systemImage: isTracked ? "bell.fill" : "bell")
            }
            .disabled(isTracked)
        }
    }
}

extension WardrobeEntry {
    /// The garment's own measurements the user entered, in cm (circumferences).
    var measurements: [GarmentDimension: Double] {
        get {
            guard let data = measurementsData,
                  let raw = try? JSONDecoder().decode([String: Double].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in GarmentDimension(rawValue: k).map { ($0, v) } })
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            measurementsData = raw.isEmpty ? nil : try? JSONEncoder().encode(raw)
        }
    }
}
