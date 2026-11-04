import Foundation
import Security

/// What the home screen widget shows: the products the user follows (price, whether the
/// wanted size is in stock) and the last checks. Built into both the app and the widget.
///
/// Handed over through a keychain item in a shared access group (the team's
/// `…com.niinova.weariq.shared`): keychain sharing needs no app group to be registered.
/// No body measurements go in it.
struct WidgetSnapshot: Codable, Equatable {
    struct Product: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var size: String?
        var price: Double?
        var currency: String?
        /// The price fell since it was first followed.
        var dropped: Bool
        var sizeInStock: Bool?
    }

    struct Check: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        /// The recommended size, or nil when none was found.
        var size: String?
    }

    var products: [Product] = []
    var checks: [Check] = []
    var updatedAt = Date()

    // MARK: Keychain

    private static let service = "com.niinova.weariq.widget"
    private static let account = "snapshot"

    /// The shared access group from Info.plist (`WQKeychainGroup`, "TEAMID.com.niinova.
    /// weariq.shared" with the team filled in at build time); nil in builds without a
    /// team (the simulator on CI), where the item stays the app's own.
    static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WQKeychainGroup") as? String,
              !group.isEmpty, !group.hasPrefix("."), !group.hasPrefix("$") else { return nil }
        return group
    }

    private static var query: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    static func load() -> WidgetSnapshot? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(Self.query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
