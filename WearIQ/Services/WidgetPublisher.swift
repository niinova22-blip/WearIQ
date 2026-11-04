import Foundation
import SwiftData
import WidgetKit

/// Writes what the widget shows and asks it to redraw: after products are re-checked,
/// followed, or a garment analysed.
@MainActor
enum WidgetPublisher {
    static func publish(_ context: ModelContext) {
        var products = FetchDescriptor<TrackedProduct>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        products.fetchLimit = 6
        var checks = FetchDescriptor<SavedAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        checks.fetchLimit = 4
        let snapshot = WidgetSnapshot(
            products: ((try? context.fetch(products)) ?? []).map { p in
                WidgetSnapshot.Product(id: p.pageURLString, name: p.productName ?? String(localized: "A product you follow"),
                                       size: p.size, price: p.lastPrice, currency: p.currency,
                                       dropped: (p.firstPrice.flatMap { first in p.lastPrice.map { $0 < first * 0.99 } }) ?? false,
                                       sizeInStock: p.sizeInStock)
            },
            checks: ((try? context.fetch(checks)) ?? []).map { a in
                WidgetSnapshot.Check(id: a.productKey, name: a.productName ?? String(localized: "Garment"),
                                     size: a.analysis?.recommendedSize?.label)
            })
        guard snapshot.products != WidgetSnapshot.load()?.products || snapshot.checks != WidgetSnapshot.load()?.checks else { return }
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
