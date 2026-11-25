import Foundation
import Security

/// macOS 登录钥匙串。后台读取静默执行，显式授权可重试不可访问的条目。
enum KeychainSecretStore {
    static let service = "ClickToKnow"

    private static let lock = NSLock()
    private static var cache: [String: SecretRead] = [:]

    static func read(account: String, allowInteraction: Bool) -> SecretRead {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[account], !allowInteraction || cached != .inaccessible {
            return cached
        }

        let result: SecretRead
        if allowInteraction {
            result = readItem(account: account)
        } else {
            result = readSilently(account: account)
        }
        cache[account] = result
        return result
    }

    private static func readSilently(account: String) -> SecretRead {
        // 现有条目在传统文件型钥匙串，使用它的交互开关。与其余钥匙串调用共用锁。
        var wasAllowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&wasAllowed) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return .inaccessible }
        defer { _ = SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        return readItem(account: account)
    }

    private static func readItem(account: String) -> SecretRead {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return .inaccessible }
        return value.isEmpty ? .missing : .value(value)
    }

    /// 写入和删除只由设置页的显式操作触发，因此可让系统请求授权。
    static func save(_ value: String, account: String) -> Bool {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return false }
        lock.lock()
        defer { lock.unlock() }

        let query = baseQuery(account: account)
        var item = query
        item[kSecValueData as String] = data
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else {
            Log.config.error("钥匙串写入失败（OSStatus \(status)）")
            return false
        }
        cache[account] = .value(value)
        return true
    }

    static func delete(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            Log.config.error("钥匙串删除失败（OSStatus \(status)）")
            return false
        }
        cache[account] = SecretRead.missing
        return true
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
