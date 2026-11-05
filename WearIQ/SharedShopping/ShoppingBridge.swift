import Foundation
import Security
import ShoppingAssistant

/// Between the app and its Safari extension: the shopper (body and style) the app leaves
/// for the extension, and the products the extension saw, waiting for the app to file
/// them. Kept in the keychain group the two share (no app group needs registering), on
/// this device only. Built into both.
enum ShoppingBridge {
    struct Entry: Codable, Equatable {
        var page: ShoppingAssistant.Page
        var advice: ShoppingAssistant.Advice
        var seenAt: Date
    }

    private static let service = "com.niinova.weariq.shopping"

    /// The shared group (`WQKeychainGroup` in Info.plist, "TEAMID.com.niinova.weariq.shared");
    /// nil in builds without a team, where the items stay the process's own.
    private static var accessGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "WQKeychainGroup") as? String,
              !group.isEmpty, !group.hasPrefix("."), !group.hasPrefix("$") else { return nil }
        return group
    }

    private static func query(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let account { q[kSecAttrAccount as String] = account }
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    private static func write(_ data: Data, account: String) {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    private static func read(account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    // MARK: Shopper

    static func saveShopper(_ shopper: ShoppingAssistant.Shopper?) {
        guard let shopper else {
            SecItemDelete(query("shopper") as CFDictionary)
            return
        }
        if let data = try? JSONEncoder().encode(shopper) { write(data, account: "shopper") }
    }

    static func shopper() -> ShoppingAssistant.Shopper? {
        read(account: "shopper").flatMap { try? JSONDecoder().decode(ShoppingAssistant.Shopper.self, from: $0) }
    }

    // MARK: Inbox

    /// One item per product page: seeing it again replaces it.
    static func enqueue(_ entry: Entry) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        write(data, account: "inbox." + digest(entry.page.url))
    }

    static func inbox() -> [(account: String, entry: Entry)] {
        var q = query()
        q[kSecReturnAttributes as String] = true
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix("inbox."),
                  let data = item[kSecValueData as String] as? Data,
                  let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
            return (account, entry)
        }
    }

    static func remove(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    /// A short stable name for a page (FNV-1a).
    static func digest(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }
}
