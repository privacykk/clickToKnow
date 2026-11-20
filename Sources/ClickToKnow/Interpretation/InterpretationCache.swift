import Foundation

/// 进程内查询缓存：同一词条（含配置指纹）重复查询直接命中，避免反复请求远程 API
/// 带来的延迟与费用。简单 LRU：超出容量淘汰最久未访问条目。
/// 仅在主线程（AppDelegate 查询路径）访问，无需加锁。
final class InterpretationCache {
    private let capacity: Int
    private var store: [String: Interpretation] = [:]
    /// 访问顺序：队尾 = 最近使用，队首 = 最久未用（淘汰候选）
    private var accessOrder: [String] = []

    init(capacity: Int = 200) {
        self.capacity = max(capacity, 1)
    }

    var count: Int { store.count }

    /// 缓存键：规范化词条 + 配置指纹。换供应商 / 换模型后旧条目自然隔离，
    /// 不会出现「换了模型却返回旧模型释义」的串味。
    static func key(term: String, baseURL: String, model: String, apiProtocol: APIProtocol) -> String {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedBase = baseURL
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return "\(apiProtocol.rawValue)|\(normalizedBase)|\(model)|\(normalizedTerm)"
    }

    func get(_ key: String) -> Interpretation? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    func put(_ key: String, _ value: Interpretation) {
        if store[key] == nil, store.count >= capacity, let oldest = accessOrder.first {
            store.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
        store[key] = value
        touch(key)
    }

    func removeAll() {
        store.removeAll()
        accessOrder.removeAll()
    }

    /// 容量固定 200，removeAll(where:) 的 O(n) 开销可忽略
    private func touch(_ key: String) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}
