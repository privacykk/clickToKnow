import Foundation

/// 进程内查询缓存：同一词条（含领域上下文与配置指纹）重复查询直接命中，
/// 避免反复请求远程 API 带来的延迟与费用。简单 LRU：超出容量淘汰最久未访问条目。
/// 仅在主线程（AppDelegate 查询路径）访问，无需加锁。
final class InterpretationCache {
    /// 缓存键：一次请求快照的摘要。
    ///
    /// 键必须覆盖所有会改变释义内容的输入，漏掉任一项都会串结果：
    /// - `source`：同一端点缺密钥时走系统词典、补上密钥后走 LLM，两者内容完全不同；
    /// - `term`：保留大小写（`US` 与 `us` 语义不同，不能合并成一条）；
    /// - `contextDigest`：领域判断依赖上下文，「helm」在 Kubernetes 段落与航海段落释义不同；
    /// - `promptFingerprint`：提示词版本 + 协议 + 归属配置，提示词改版或换配置后旧条目必须失效。
    struct Key: Hashable, CustomStringConvertible {
        let source: Interpretation.Source
        let baseURL: String
        let model: String
        let term: String
        let contextDigest: String
        let promptFingerprint: String

        /// 仅用于日志与测试断言：不含上下文原文与密钥
        var description: String {
            "\(source.rawValue)|\(baseURL)|\(model)|\(term)|\(promptFingerprint)|ctx:\(contextDigest.count)"
        }
    }

    /// 提示词版本号：`LLMProviderSupport.systemPrompt` 语义变化时递增，令旧缓存整体失效
    static let promptVersion = "1"

    /// 上下文摘要的最大字符数：足够区分领域，又不会让键无限增长
    static let contextDigestLimit = 160

    private let capacity: Int
    private var store: [Key: Interpretation] = [:]
    /// 访问顺序：队尾 = 最近使用，队首 = 最久未用（淘汰候选）
    private var accessOrder: [Key] = []

    init(capacity: Int = 200) {
        self.capacity = max(capacity, 1)
    }

    /// 当前缓存条目数（状态页展示用）
    var count: Int { store.count }

    /// 构造缓存键。参数应取自查询开始时的配置快照，而不是响应结束时的可变配置。
    static func key(
        term: String,
        context: String?,
        source: Interpretation.Source,
        baseURL: String,
        model: String,
        apiProtocol: APIProtocol,
        profileID: UUID?
    ) -> Key {
        Key(
            source: source,
            baseURL: normalizedBaseURL(baseURL),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            term: normalizedTerm(term),
            contextDigest: contextDigest(context),
            promptFingerprint: "\(promptVersion)|\(apiProtocol.rawValue)|\(profileID?.uuidString ?? "none")"
        )
    }

    /// 词条规范化：只压空白，不转小写。大小写有意义的词条（US / us、HTTP / http）必须分开缓存。
    static func normalizedTerm(_ term: String) -> String {
        term.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// 端点规范化：去空白、去尾部斜杠、转小写（同一端点的不同写法应命中同一条缓存）
    static func normalizedBaseURL(_ baseURL: String) -> String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    /// 上下文摘要：空白归一 + 转小写后截断。
    /// 不做全文去重压缩——上下文原样参与键，才能保证「同词不同上下文绝不串结果」；
    /// 代价是同一篇文章里上下文略有差异时不会命中，这是可接受的正确性优先取舍。
    static func contextDigest(_ context: String?) -> String {
        guard let context else { return "" }
        let normalized = context
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        return String(normalized.prefix(contextDigestLimit))
    }

    /// 命中即刷新访问顺序（维持 LRU 语义）
    func get(_ key: Key) -> Interpretation? {
        guard let value = store[key] else { return nil }
        touch(key)
        return value
    }

    /// 写入缓存：仅当新增条目且已达容量时，淘汰最久未用条目
    func put(_ key: Key, _ value: Interpretation) {
        if store[key] == nil, store.count >= capacity, let oldest = accessOrder.first {
            store.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
        store[key] = value
        touch(key)
    }

    /// 清空缓存（配置变更 / 手动清理后由调用方触发，防旧释义串味）
    func removeAll() {
        store.removeAll()
        accessOrder.removeAll()
    }

    /// 容量固定 200，removeAll(where:) 的 O(n) 开销可忽略
    private func touch(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}