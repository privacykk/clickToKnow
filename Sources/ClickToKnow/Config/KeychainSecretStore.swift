import Foundation
import Security

/// 钥匙串通用密码存取（service=ClickToKnow）。
/// 裸可执行文件为 ad-hoc 签名且每次重编译签名变化，钥匙串访问可能触发系统询问或被拒，
/// 因此所有失败都消化为返回值（false/nil），由调用方（AppConfig）回退 UserDefaults。
/// 读取结果（含「确实没有条目」）做内存缓存：状态页每秒轮询密钥来源，
/// 若只缓存命中结果，未配置密钥时会每秒向 securityd 发起多次查询，ad-hoc 场景还会反复弹框。
enum KeychainSecretStore {
    static let service = "ClickToKnow"

    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    /// 已确认不存在/不可读的 account：避免每秒重复查询与重复弹系统授权框
    private static var missing: Set<String> = []

    /// 探测一次钥匙串可用性并缓存（errSecItemNotFound 说明查询本身被允许，仅条目不存在）
    static let isAvailable: Bool = {
        var query = baseQuery(account: "__availability_probe__")
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }()

    /// 写入（存在则覆盖）。返回是否成功；失败时调用方回退本地存储。
    @discardableResult
    static func save(_ value: String, account: String = "apiKey") -> Bool {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return false }
        guard isAvailable else { return false }
        var query = baseQuery(account: account)
        // 先查后写：已存在走 Update，避免 errSecDuplicateItem
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let status: OSStatus
        if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            // 日志只带状态码，绝不含密钥值
            Log.config.error("钥匙串写入失败（OSStatus \(status)），回退 UserDefaults")
            return false
        }
        lock.lock()
        cache[account] = value
        missing.remove(account)
        lock.unlock()
        return true
    }

    static func load(account: String = "apiKey") -> String? {
        lock.lock()
        let cached = cache[account]
        let knownMissing = missing.contains(account)
        lock.unlock()
        if let cached { return cached }
        if knownMissing { return nil }
        guard isAvailable else { return cacheMiss(account) }

        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return cacheMiss(account)
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            // 被拒/询问失败等：缓存「读不到」，避免轮询期间反复触发系统框
            return cacheMiss(account)
        }
        lock.lock()
        cache[account] = value
        missing.remove(account)
        lock.unlock()
        return value
    }

    /// 删除幂等：条目不存在视为成功。返回是否确认删除成功——
    /// 失败（如 ad-hoc 重签名后被拒）时保留缓存，UI 才能如实提示「密钥可能仍生效」。
    @discardableResult
    static func delete(account: String = "apiKey") -> Bool {
        guard isAvailable else { return false }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        let succeeded = status == errSecSuccess || status == errSecItemNotFound
        if !succeeded {
            Log.config.error("钥匙串删除失败（OSStatus \(status)）")
            return false
        }
        lock.lock()
        cache.removeValue(forKey: account)
        missing.insert(account)
        lock.unlock()
        return true
    }

    private static func cacheMiss(_ account: String) -> String? {
        lock.lock()
        missing.insert(account)
        lock.unlock()
        return nil
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
