import XCTest

@testable import ClickToKnow

/// 查询缓存：命中、键规范化（大小写/空白/尾斜杠不敏感）、配置指纹隔离、LRU 淘汰。
final class InterpretationCacheTests: XCTestCase {
    private func makeKey(
        term: String = "helm",
        baseURL: String = "https://api.deepseek.com",
        model: String = "deepseek-chat",
        apiProtocol: APIProtocol = .openAICompatible
    ) -> String {
        InterpretationCache.key(term: term, baseURL: baseURL, model: model, apiProtocol: apiProtocol)
    }

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

    /// 词条大小写与首尾空白不敏感：「Helm」与「 helm 」同键
    func test_key_normalizesTerm() {
        let a = InterpretationCache.key(term: " helm ", baseURL: "u", model: "m", apiProtocol: .openAICompatible)
        let b = InterpretationCache.key(term: "Helm", baseURL: "u", model: "m", apiProtocol: .openAICompatible)
        XCTAssertEqual(a, b)
    }

    /// Base URL 的尾斜杠与大小写不敏感
    func test_key_normalizesBaseURL() {
        let a = makeKey(baseURL: "https://api.deepseek.com/")
        let b = makeKey(baseURL: "HTTPS://API.DEEPSEEK.COM")
        XCTAssertEqual(a, b)
    }

    /// 换供应商/模型/协议后旧缓存自然隔离
    func test_key_configFingerprintIsolates() {
        let cache = InterpretationCache()
        cache.put(makeKey(model: "deepseek-chat"), makeValue())
        XCTAssertNil(cache.get(makeKey(model: "deepseek-reasoner")))
        XCTAssertNil(cache.get(makeKey(baseURL: "https://api.moonshot.cn/v1")))
        XCTAssertNil(cache.get(makeKey(apiProtocol: .anthropic)))
    }

    /// 超出容量时淘汰最久未访问的条目
    func test_evictsLeastRecentlyUsed() {
        let cache = InterpretationCache(capacity: 2)
        cache.put("a", makeValue())
        cache.put("b", makeValue())
        _ = cache.get("a") // a 变最近使用，b 成为淘汰候选
        cache.put("c", makeValue())
        XCTAssertNotNil(cache.get("a"))
        XCTAssertNil(cache.get("b"))
        XCTAssertEqual(cache.count, 2)
    }

    /// 同键覆盖不膨胀容量
    func test_putSameKey_doesNotGrow() {
        let cache = InterpretationCache(capacity: 2)
        cache.put("a", makeValue())
        cache.put("a", makeValue())
        XCTAssertEqual(cache.count, 1)
    }

    func test_removeAll() {
        let cache = InterpretationCache()
        cache.put("a", makeValue())
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.get("a"))
    }
}
