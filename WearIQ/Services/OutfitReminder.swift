import Foundation
import UserNotifications

/// An optional daily nudge at 8:00 to open the outfit of the day.
enum OutfitReminder {
    private static let identifier = "weariq.outfit-reminder"

    static func set(_ on: Bool) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard on, (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "What to wear today?")
        content.body = String(localized: "Your outfit of the day is ready in the Style tab.")
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 8, minute: 0), repeats: true)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
