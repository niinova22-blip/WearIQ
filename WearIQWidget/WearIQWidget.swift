import SwiftUI
import WidgetKit

/// Home screen widget: followed products (price drops, the wanted size back in stock)
/// and the latest checks with their sizes. Reads the snapshot the app leaves for it.
@main
struct WearIQWidgetBundle: WidgetBundle {
    var body: some Widget {
        FollowedProductsWidget()
    }
}

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetSnapshot(
            products: [.init(id: "1", name: "Linen shirt", size: "M", price: 899, currency: "TRY", dropped: true, sizeInStock: true)],
            checks: [.init(id: "2", name: "Slim jeans", size: "32")]))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app asks for a reload when something changes; otherwise every few hours.
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(Date(timeIntervalSinceNow: 4 * 3600))))
    }
}

struct FollowedProductsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FollowedProducts", provider: SnapshotProvider()) { entry in
            FollowedProductsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("WearIQ")
        .description("Price drops and sizes back in stock for what you follow, and your latest checks.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct FollowedProductsView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let products = entry.snapshot?.products ?? []
        let checks = entry.snapshot?.checks ?? []
        VStack(alignment: .leading, spacing: 6) {
            Label("WearIQ", systemImage: "tshirt.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
            if products.isEmpty && checks.isEmpty {
                Spacer()
                Text("Check a garment or follow a product to see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(products.prefix(family == .systemSmall ? 2 : 3)) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            if let price = p.price {
                                Text(price, format: .currency(code: p.currency ?? "TRY").precision(.fractionLength(0)))
                                    .foregroundStyle(p.dropped ? Color.green : Color.secondary)
                            }
                            if p.dropped { Image(systemName: "arrow.down").foregroundStyle(.green) }
                            if let size = p.size, let inStock = p.sizeInStock {
                                Text(inStock ? "\(size) in stock" : "\(size) sold out")
                                    .foregroundStyle(inStock ? Color.primary : Color.secondary)
                            }
                        }
                        .font(.caption2)
                    }
                }
                if family != .systemSmall || products.isEmpty {
                    ForEach(checks.prefix(products.isEmpty ? 3 : 2)) { c in
                        HStack {
                            Text(c.name).lineLimit(1)
                            Spacer()
                            Text(c.size ?? "–").bold()
                        }
                        .font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(URL(string: "weariq://open"))
    }
}
