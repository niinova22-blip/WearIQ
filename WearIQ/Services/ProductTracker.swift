import BackgroundTasks
import Foundation
import ProductMeasurementParser
import SwiftData
import UserNotifications

/// Follows saved products for a price drop or the wanted size coming back in stock, and
/// tells the user with a local notification. Checks run when the app opens and, when iOS
/// allows it, in the background a few times a day. Only the page's structured data is
/// read (a plain request, no browser, no sign-in).
@MainActor
enum ProductTracker {
    static let taskIdentifier = "com.niinova.weariq.track"

    struct Change: Equatable {
        enum Kind: Equatable {
            case priceDropped(from: Double, to: Double, currency: String?)
            case backInStock(size: String)
        }

        var productName: String
        var kind: Kind
    }

    /// Asks for notification permission the first time something is tracked.
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func track(_ product: TrackedProduct, in context: ModelContext) async {
        let url = product.pageURLString
        let existing = FetchDescriptor<TrackedProduct>(predicate: #Predicate { $0.pageURLString == url })
        try? context.fetch(existing).forEach(context.delete)
        context.insert(product)
        try? context.save()
        await requestPermission()
        scheduleBackgroundCheck()
    }

    /// What changed since the last check, for one product.
    static func changes(for product: TrackedProduct, now info: ProductInfo) -> [Change] {
        let name = product.productName ?? info.name ?? String(localized: "A product you follow")
        var found: [Change] = []
        if let old = product.lastPrice, let new = info.price, new < old * 0.99 {
            found.append(Change(productName: name, kind: .priceDropped(from: old, to: new, currency: info.currency ?? product.currency)))
        }
        if let size = product.size, let inStock = info.sizeStock[size], inStock, product.sizeInStock == false {
            found.append(Change(productName: name, kind: .backInStock(size: size)))
        }
        return found
    }

    /// Re-reads every followed product, records the new state and notifies changes.
    @discardableResult
    static func refreshAll(in context: ModelContext, service: ProductDataService = ProductDataService()) async -> [Change] {
        guard let products = try? context.fetch(FetchDescriptor<TrackedProduct>()) else { return [] }
        var all: [Change] = []
        for product in products {
            guard let url = product.pageURL, let info = try? await service.structuredInfo(at: url) else { continue }
            let found = changes(for: product, now: info)
            all += found
            if let price = info.price { product.lastPrice = price }
            if let currency = info.currency { product.currency = currency }
            if let size = product.size, let inStock = info.sizeStock[size] { product.sizeInStock = inStock }
            product.lastCheckedAt = Date()
            for change in found { await notify(change) }
        }
        try? context.save()
        return all
    }

    private static func notify(_ change: Change) async {
        let content = UNMutableNotificationContent()
        content.title = change.productName
        switch change.kind {
        case let .priceDropped(from, to, currency):
            let format = FloatingPointFormatStyle<Double>.Currency(code: currency ?? "TRY")
            content.body = String(localized: "Price dropped from \(from.formatted(format)) to \(to.formatted(format)).")
        case let .backInStock(size):
            content.body = String(localized: "Your size \(size) is back in stock.")
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: Background

    /// Registers the background check; call once at launch, before the app finishes launching.
    static func registerBackgroundTask(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            let work = Task { @MainActor in
                scheduleBackgroundCheck()
                await refreshAll(in: container.mainContext)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func scheduleBackgroundCheck() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
