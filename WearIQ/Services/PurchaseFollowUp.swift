import FitEngine
import Foundation
import SwiftData
import UserNotifications

/// "Ordered it": a reminder a few days later, when the parcel has usually arrived, asks
/// how it fit. The answer goes into the brand memory and the fit record on the profile.
@MainActor
enum PurchaseFollowUp {
    /// Typical delivery time before asking.
    static let delay: TimeInterval = 4 * 24 * 3600

    static func schedule(_ record: PurchaseRecord) async {
        guard let token = record.token else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Did it arrive?")
        let name = record.productName ?? record.brand
        content.body = String(localized: "How does \(name) in \(record.size) fit? One tap helps your next size.")
        content.sound = .default
        content.userInfo = ["purchaseToken": token]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "purchase.\(token)", content: content, trigger: trigger))
    }

    static func cancel(_ record: PurchaseRecord) {
        guard let token = record.token else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["purchase.\(token)"])
    }

    /// The fit record from every purchase: each one's usual size is the size taken in the
    /// previous purchase of that brand and kind.
    static func summary(_ records: [PurchaseRecord]) -> FitOutcomeSummary {
        let ordered = records.sorted { $0.createdAt < $1.createdAt }
        var outcomes: [PurchaseOutcome] = []
        for (i, r) in ordered.enumerated() {
            let earlier = ordered[..<i].last { $0.brand.lowercased() == r.brand.lowercased() && $0.categoryRaw == r.categoryRaw }
            let fit: PurchaseOutcome.Fit? = r.isPending && r.returned != true ? nil : PurchaseOutcome.Fit(rawValue: r.feelRaw)
            outcomes.append(PurchaseOutcome(recommended: r.recommendedSize, taken: r.size, usual: earlier?.size,
                                            fit: fit, returned: r.returned == true))
        }
        return FitOutcomeSummary(outcomes)
    }
}

/// Routes notification taps: a purchase reminder opens its fit question.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    /// Set at launch; receives the purchase token.
    @MainActor var onPurchase: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let token = response.notification.request.content.userInfo["purchaseToken"] as? String
        Task { @MainActor in
            if let token { self.onPurchase?(token) }
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
