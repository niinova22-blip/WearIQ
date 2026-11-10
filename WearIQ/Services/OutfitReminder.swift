import Foundation
import UserNotifications

/// An optional daily nudge at 8:00 to open the outfit of the day.
enum OutfitReminder {
    private static let identifier = "weariq.outfit-reminder"

    /// False when it should be on but notifications aren't allowed (the toggle goes back off).
    @discardableResult
    static func set(_ on: Bool) async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard on else { return true }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "What to wear today?")
        content.body = String(localized: "Your outfit of the day is ready in the Style tab.")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 8, minute: 0), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        return true
    }
}
