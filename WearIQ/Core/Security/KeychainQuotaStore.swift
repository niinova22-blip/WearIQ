import Foundation
import ScanQuota
import Security

/// Keeps the daily scan quota in the Keychain so deleting and reinstalling the app
/// does not hand out a fresh allowance. Device-only, never synced to iCloud.
final class KeychainQuotaStore: QuotaStateStore {
    private let service: String
    private let account = "dailyScanQuota"

    init(service: String = "com.niinova.weariq.quota") {
        self.service = service
    }

    func load() -> QuotaState? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(QuotaState.self, from: data)
    }

    func save(_ state: QuotaState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(baseQuery.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
