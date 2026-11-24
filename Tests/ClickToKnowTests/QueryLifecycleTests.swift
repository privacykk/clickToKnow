import XCTest

@testable import ClickToKnow

/// 查询生命周期：代际失效（评审问题 4）与配置快照（问题 3 / 4 的共同前提）。
final class QueryLifecycleTests: XCTestCase {
    // MARK: - QuerySession

    /// 新查询取代旧查询：旧 id 立刻失效，增量/成功/失败都不得再落到 UI
    @MainActor
    func test_beginInvalidatesPreviousSession() {
        let session = QuerySession()
        let first = session.begin()
        XCTAssertTrue(session.isCurrent(first))

        let second = session.begin()
        XCTAssertFalse(session.isCurrent(first), "旧会话必须立刻失效")
        XCTAssertTrue(session.isCurrent(second))
    }

    /// 关闭弹窗 / 暂停取词只调用 invalidate：当前会话失效，且没有新会话顶上
    @MainActor
    func test_invalidateKillsCurrentSession() {
        let session = QuerySession()
        let id = session.begin()
        session.invalidate()
        XCTAssertFalse(session.isCurrent(id), "关闭后旧响应不得重新弹窗")
        XCTAssertNil(session.currentID)
    }

    /// 自动关闭定时器可能在查询成功后再触发一次 invalidate：必须是无副作用的幂等操作
    @MainActor
    func test_invalidateIsIdempotent() {
        let session = QuerySession()
        let id = session.begin()
        session.invalidate()
        session.invalidate()
        XCTAssertFalse(session.isCurrent(id))
        XCTAssertNil(session.currentID)

        let next = session.begin()
        XCTAssertTrue(session.isCurrent(next), "失效后仍能开始新会话")
    }

    /// 会话 id 单调递增，不会因为失效而回到旧值（避免旧响应恰好匹配新会话）
    @MainActor
    func test_sessionIDsAreMonotonic() {
        let session = QuerySession()
        let first = session.begin()
        session.invalidate()
        let second = session.begin()
        session.invalidate()
        let third = session.begin()
        XCTAssertLessThan(first, second)
        XCTAssertLessThan(second, third)
        XCTAssertFalse(session.isCurrent(first))
        XCTAssertFalse(session.isCurrent(second))
        XCTAssertTrue(session.isCurrent(third))
    }

    // MARK: - QuerySnapshot

    /// 端点/模型齐备 + 有密钥 → 走 LLM，历史记录归属该模型
    func test_snapshotUsesLLMWhenKeyPresent() {
        let snapshot = QuerySnapshot(
            profileID: UUID(),
            apiProtocol: .openAICompatible,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKey: "sk-test"
        )
        XCTAssertTrue(snapshot.usesLLM)
        XCTAssertEqual(snapshot.source, .llm)
        XCTAssertEqual(snapshot.historyModel, "deepseek-chat")
    }

    /// 同一端点缺密钥 → 回落系统词典；历史不得谎报成某个模型
    func test_snapshotFallsBackToDictionaryWithoutKey() {
        let snapshot = QuerySnapshot(
            profileID: UUID(),
            apiProtocol: .openAICompatible,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKey: ""
        )
        XCTAssertFalse(snapshot.usesLLM)
        XCTAssertEqual(snapshot.source, .systemDictionary)
        XCTAssertNil(snapshot.historyModel)
    }

    /// 密钥可选预设（Ollama 本地）无密钥也走 LLM
    func test_snapshotUsesLLMForKeyOptionalPreset() {
        let snapshot = QuerySnapshot(
            profileID: UUID(),
            apiProtocol: .openAICompatible,
            baseURL: "http://localhost:11434/v1",
            model: "llama3.1",
            apiKey: ""
        )
        XCTAssertTrue(snapshot.usesLLM)
        XCTAssertEqual(snapshot.historyModel, "llama3.1")
    }

    /// 快照里只保留清洗后的密钥：换行会让 CFNetwork 静默丢弃 Authorization 头
    func test_snapshotSanitizesAPIKey() {
        let snapshot = QuerySnapshot(
            profileID: nil,
            apiProtocol: .openAICompatible,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKey: "sk-te\nst\t "
        )
        XCTAssertEqual(snapshot.apiKey, "sk-test")
        XCTAssertTrue(snapshot.usesLLM)
    }

    /// 来源进入缓存键：同端点同词条，词典结果与 LLM 结果互不命中
    func test_snapshotSourceParticipatesInCacheKey() {
        let dictionary = QuerySnapshot(
            profileID: nil, apiProtocol: .openAICompatible,
            baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKey: ""
        )
        let llm = QuerySnapshot(
            profileID: nil, apiProtocol: .openAICompatible,
            baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKey: "sk-test"
        )
        func key(_ snapshot: QuerySnapshot) -> InterpretationCache.Key {
            InterpretationCache.key(
                term: "helm", context: "k8s 集群里安装服务", source: snapshot.source,
                baseURL: snapshot.baseURL, model: snapshot.model,
                apiProtocol: snapshot.apiProtocol, profileID: snapshot.profileID
            )
        }
        XCTAssertNotEqual(key(dictionary), key(llm))
    }

    /// 请求被取消时 URLError 必须还原成 CancellationError，否则会退化成「查询失败」重新弹窗
    func test_cancelledURLErrorBecomesCancellationError() {
        let cancelled = LLMProviderSupport.networkError(URLError(.cancelled))
        XCTAssertTrue(cancelled is CancellationError)

        let timedOut = LLMProviderSupport.networkError(URLError(.timedOut))
        XCTAssertFalse(timedOut is CancellationError, "超时仍应展示为可读错误")
        XCTAssertTrue(timedOut is InterpretationError)
    }
}