import XCTest

@testable import ClickToKnow

/// 查询缓存：命中、键规范化、来源/上下文/配置隔离、LRU 淘汰。
///
/// 键的正确性是缓存功能的全部意义所在——键漏了哪个维度，就会在该维度上串结果。
/// 这里逐条覆盖评审列出的三种串味场景：同词不同上下文、大小写差异、词典 ↔ LLM。
final class InterpretationCacheTests: XCTestCase {
    /// 构造缓存键（默认参数便于各用例微调单个字段）
    private func makeKey(
        term: String = "helm",
        context: String? = nil,
        source: Interpretation.Source = .llm,
        baseURL: String = "https://api.deepseek.com",
        model: String = "deepseek-chat",
        apiProtocol: APIProtocol = .openAICompatible,
        profileID: UUID? = UUID(uuidString: "11111111-1111-1111-1111-111111111111")
    ) -> InterpretationCache.Key {
        InterpretationCache.key(
            term: term,
            context: context,
            source: source,
            baseURL: baseURL,
            model: model,
            apiProtocol: apiProtocol,
            profileID: profileID
        )
    }

    /// 构造缓存值
    private func makeValue(_ term: String = "helm") -> Interpretation {
        Interpretation(term: term, content: "Kubernetes 包管理器", source: .llm)
    }

    func test_putThenGet_hits() {
        let cache = InterpretationCache()
        let key = makeKey()
        cache.put(key, makeValue())
        XCTAssertEqual(cache.get(key)?.content, "Kubernetes 包管理器")
    }

    func test_getMiss_returnsNil() {
        XCTAssertNil(InterpretationCache().get(makeKey()))
    }

    /// 词条仅压空白、不转小写：`US` 与 `us` 语义不同，必须各存一条
    func test_key_preservesTermCase() {
        let upper = makeKey(term: "US")
        let lower = makeKey(term: "us")
        XCTAssertNotEqual(upper, lower)

        let cache = InterpretationCache()
        cache.put(upper, Interpretation(term: "US", content: "美国", source: .llm))
        cache.put(lower, Interpretation(term: "us", content: "我们（宾格）", source: .llm))
        XCTAssertEqual(cache.get(upper)?.content, "美国")
        XCTAssertEqual(cache.get(lower)?.content, "我们（宾格）")
        XCTAssertEqual(cache.count, 2)
    }

    /// 首尾空白与内部连续空白不影响键：「 helm 」与「helm」同键
    func test_key_normalizesTermWhitespace() {
        XCTAssertEqual(makeKey(term: " helm "), makeKey(term: "helm"))
        XCTAssertEqual(makeKey(term: "data   plane"), makeKey(term: "data plane"))
        XCTAssertEqual(makeKey(term: "helm\n"), makeKey(term: "helm"))
    }

    /// 同词不同上下文不得共用缓存：Kubernetes 段落里的 helm 与航海段落里的 helm 释义不同
    func test_key_contextIsolates() {
        let kubernetes = makeKey(context: "helm install my-release bitnami/wordpress")
        let sailing = makeKey(context: "他握紧了 helm，迎着风浪调整航向")
        XCTAssertNotEqual(kubernetes, sailing)

        let cache = InterpretationCache()
        cache.put(kubernetes, Interpretation(term: "helm", content: "Kubernetes 包管理器", source: .llm))
        cache.put(sailing, Interpretation(term: "helm", content: "舵", source: .llm))
        XCTAssertEqual(cache.get(kubernetes)?.content, "Kubernetes 包管理器")
        XCTAssertEqual(cache.get(sailing)?.content, "舵")
    }

    /// 无上下文与空上下文等价（⌘C 兜底路径传 nil）
    func test_key_nilAndEmptyContextAreEquivalent() {
        XCTAssertEqual(makeKey(context: nil), makeKey(context: ""))
        XCTAssertEqual(makeKey(context: nil), makeKey(context: "   \n "))
    }

    func test_contextDigest_includesTheEntireContextAndPreservesCase() {
        let prefix = String(repeating: "a", count: 200)
        XCTAssertNotEqual(makeKey(context: prefix + " Kubernetes"), makeKey(context: prefix + " sailing"))
        XCTAssertNotEqual(makeKey(context: "US"), makeKey(context: "us"))
        XCTAssertEqual(InterpretationCache.contextDigest(prefix).count, 44)
    }

    /// 词典结果与 LLM 结果必须分键：同一端点缺密钥时入缓存的是词典，补上密钥后不得再命中
    func test_key_sourceIsolates() {
        let dictionary = makeKey(source: .systemDictionary)
        let llm = makeKey(source: .llm)
        XCTAssertNotEqual(dictionary, llm)

        let cache = InterpretationCache()
        cache.put(dictionary, Interpretation(term: "helm", content: "舵", source: .systemDictionary))
        XCTAssertNil(cache.get(llm), "补上密钥后不应命中缺密钥期间缓存下来的词典结果")
    }

    /// Base URL 的尾斜杠与大小写不敏感
    func test_key_normalizesBaseURL() {
        XCTAssertEqual(makeKey(baseURL: "https://api.deepseek.com/"), makeKey(baseURL: "HTTPS://API.DEEPSEEK.COM"))
    }

    /// 换供应商/模型/协议/配置后旧缓存自然隔离
    func test_key_configFingerprintIsolates() {
        let cache = InterpretationCache()
        cache.put(makeKey(model: "deepseek-chat"), makeValue())
        XCTAssertNil(cache.get(makeKey(model: "deepseek-reasoner")))
        XCTAssertNil(cache.get(makeKey(baseURL: "https://api.moonshot.cn/v1")))
        XCTAssertNil(cache.get(makeKey(apiProtocol: .anthropic)))
        XCTAssertNil(cache.get(makeKey(profileID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"))))
        XCTAssertNil(cache.get(makeKey(profileID: nil)))
    }

    /// 超出容量时淘汰最久未访问的条目
    func test_evictsLeastRecentlyUsed() {
        let cache = InterpretationCache(capacity: 2)
        let a = makeKey(term: "a")
        let b = makeKey(term: "b")
        let c = makeKey(term: "c")
        cache.put(a, makeValue())
        cache.put(b, makeValue())
        _ = cache.get(a) // a 变最近使用，b 成为淘汰候选
        cache.put(c, makeValue())
        XCTAssertNotNil(cache.get(a))
        XCTAssertNil(cache.get(b))
        XCTAssertEqual(cache.count, 2)
    }

    /// 同键覆盖不膨胀容量
    func test_putSameKey_doesNotGrow() {
        let cache = InterpretationCache(capacity: 2)
        let a = makeKey(term: "a")
        cache.put(a, makeValue())
        cache.put(a, makeValue())
        XCTAssertEqual(cache.count, 1)
    }

    /// 配置变更后清空：AppDelegate 监听 AppConfig.llmConfigChangedNotification 触发
    func test_removeAll() {
        let cache = InterpretationCache()
        let key = makeKey()
        cache.put(key, makeValue())
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.get(key))
    }
}
