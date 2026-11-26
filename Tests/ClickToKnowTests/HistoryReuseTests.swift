import XCTest

@testable import ClickToKnow

/// 第三步：按查询指纹复用本地历史。
/// 断言重点是「条件不同不串用」「删除/清空后不再命中」「迁移记录无指纹不参与」。
@MainActor
final class HistoryReuseTests: XCTestCase {
    private var directory: URL!
    private var store: HistoryStore!
    /// 固定配置 id，避免每次 UUID 不同导致指纹漂移
    private let profileID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickToKnowReuse-\(UUID().uuidString)", isDirectory: true)
        store = HistoryStore(directory: directory, autostart: false)
        store.prepareSynchronously()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
        super.tearDown()
    }

    private func fingerprint(
        _ term: String, context: String? = nil, source: Interpretation.Source = .llm,
        baseURL: String = "https://api.example.com/v1", model: String = "deepseek-chat",
        style: ExplanationStyle = .technical
    ) -> String {
        QueryFingerprint.make(
            term: term, context: context, source: source, baseURL: baseURL, model: model,
            apiProtocol: .openAICompatible, profileID: profileID, explanationStyle: style
        )
    }

    private func addEntry(_ term: String, content: String, fingerprint: String?) -> HistoryEntry.ID {
        store.add(
            Interpretation(term: term, content: content, source: .llm),
            model: "deepseek-chat", fingerprint: fingerprint
        )
    }

    // MARK: - 指纹本身

    func test_fingerprintStableAndCoversEveryDimension() {
        let base = fingerprint("helm")

        XCTAssertEqual(base, fingerprint("helm"), "同一条件必须得到同一指纹（跨进程可用）")
        XCTAssertNotEqual(base, fingerprint("helm", context: "k8s 上下文"), "上下文不同不得复用")
        XCTAssertNotEqual(base, fingerprint("helm", model: "gpt-4o"), "模型不同不得复用")
        XCTAssertNotEqual(base, fingerprint("helm", source: .systemDictionary), "词典释义不得当大模型结果复用")
        XCTAssertNotEqual(base, fingerprint("helm", style: .translation), "释义模板不同不得复用")
        XCTAssertNotEqual(base, fingerprint("helm", baseURL: "https://other.example.com/v1"), "端点不同不得复用")
        XCTAssertNotEqual(base, fingerprint("Helm"), "大小写有意义的词条不得合并")
    }

    /// 端点写法差异（大小写、尾斜杠）与缓存键一致，视为同一条件
    func test_fingerprintNormalizesBaseURL() {
        XCTAssertEqual(
            fingerprint("helm", baseURL: "https://API.example.com/v1/"),
            fingerprint("helm", baseURL: "https://api.example.com/v1")
        )
    }

    /// 指纹是摘要，不含词条与上下文原文（历史里只存这个摘要即可判等）
    func test_fingerprintDoesNotLeakContent() {
        let fp = fingerprint("绝密词条", context: "这是一段不该出现在指纹里的上下文")
        XCTAssertFalse(fp.contains("绝密"))
        XCTAssertFalse(fp.contains("上下文"))
        XCTAssertTrue(fp.hasPrefix("v\(QueryFingerprint.version)-"))
    }

    // MARK: - 历史复用

    func test_reusesNewestMatchingEntry() {
        let fp = fingerprint("helm")
        addEntry("helm", content: "旧释义", fingerprint: fp)
        addEntry("helm", content: "新释义", fingerprint: fp)

        XCTAssertEqual(store.reusableEntry(fingerprint: fp)?.content, "新释义")
        XCTAssertEqual(store.reusableEntryCount, 1, "同一指纹只保留最新一条")
    }

    func test_differentFingerprintIsMiss() {
        addEntry("helm", content: "包管理器", fingerprint: fingerprint("helm"))
        XCTAssertNil(store.reusableEntry(fingerprint: fingerprint("helm", model: "其他模型")))
    }

    func test_migratedEntryWithoutFingerprintIsNotReusable() {
        addEntry("helm", content: "迁移来的记录", fingerprint: nil)
        XCTAssertNil(store.reusableEntry(fingerprint: fingerprint("helm")))
        XCTAssertEqual(store.reusableEntryCount, 0)
        XCTAssertEqual(store.entries.count, 1, "记录仍可浏览")
    }

    /// 删除记录后不再命中，并广播被删指纹供内存缓存失效
    func test_deleteInvalidatesReuse() {
        let fp = fingerprint("helm")
        let id = addEntry("helm", content: "包管理器", fingerprint: fp)
        XCTAssertNotNil(store.reusableEntry(fingerprint: fp))

        var notified: (fingerprints: [String], ids: [HistoryEntry.ID])?
        let token = NotificationCenter.default.addObserver(
            forName: HistoryStore.didRemoveHistoryNotification, object: store, queue: nil
        ) { notification in
            notified = (
                notification.userInfo?["fingerprints"] as? [String] ?? [],
                notification.userInfo?["ids"] as? [HistoryEntry.ID] ?? []
            )
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.remove(id: id)

        XCTAssertNil(store.reusableEntry(fingerprint: fp), "删除后不得再复用")
        XCTAssertEqual(notified?.fingerprints, [fp])
        XCTAssertEqual(notified?.ids, [id])
    }

    /// 清空历史后全部失效，且被删指纹一并广播（内存缓存也要清）
    func test_clearInvalidatesReuse() {
        let first = fingerprint("helm")
        let second = fingerprint("ingress")
        addEntry("helm", content: "a", fingerprint: first)
        addEntry("ingress", content: "b", fingerprint: second)

        var notified: [String] = []
        let token = NotificationCenter.default.addObserver(
            forName: HistoryStore.didRemoveHistoryNotification, object: store, queue: nil
        ) { notification in
            notified = notification.userInfo?["fingerprints"] as? [String] ?? []
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.removeAll()

        XCTAssertNil(store.reusableEntry(fingerprint: first))
        XCTAssertNil(store.reusableEntry(fingerprint: second))
        XCTAssertEqual(Set(notified), Set([first, second]))
    }

    /// 自动裁剪（保留条数）淘汰的记录同样失效
    func test_trimInvalidatesReuse() {
        let fp = fingerprint("helm")
        addEntry("helm", content: "包管理器", fingerprint: fp)
        for index in 0..<4 {
            addEntry("term-\(index)", content: "x", fingerprint: fingerprint("term-\(index)"))
        }
        XCTAssertNotNil(store.reusableEntry(fingerprint: fp))

        store.applyRetentionLimit(2)

        XCTAssertNil(store.reusableEntry(fingerprint: fp), "被裁掉的记录不得再复用")
        XCTAssertEqual(store.reusableEntryCount, 2)
    }

    /// 重启后仍能复用（指纹不依赖进程内 hash）
    func test_reuseSurvivesRestart() {
        let fp = fingerprint("helm")
        addEntry("helm", content: "包管理器", fingerprint: fp)
        store.flush()

        let reopened = HistoryStore(directory: directory, autostart: false)
        reopened.prepareSynchronously()

        XCTAssertEqual(reopened.reusableEntry(fingerprint: fp)?.content, "包管理器")
    }

    // MARK: - 内存缓存联动

    func test_cacheEntriesEvictedByFingerprint() {
        let cache = InterpretationCache()
        func key(_ term: String) -> InterpretationCache.Key {
            InterpretationCache.key(
                term: term, context: nil, source: .llm,
                baseURL: "https://api.example.com/v1", model: "deepseek-chat",
                apiProtocol: .openAICompatible, profileID: profileID
            )
        }
        let keep = key("ingress")
        let drop = key("helm")
        cache.put(keep, Interpretation(term: "ingress", content: "b", source: .llm))
        cache.put(drop, Interpretation(term: "helm", content: "a", source: .llm))

        cache.removeEntries(matchingFingerprints: [QueryFingerprint.make(from: drop)])

        XCTAssertNil(cache.get(drop), "删除历史后对应内存缓存必须失效")
        XCTAssertEqual(cache.get(keep)?.content, "b")
    }

    /// 复用开关默认开启；关掉后隐私设置广播（AppDelegate 据此清空当前会话缓存）
    func test_reuseTogglePersists() throws {
        let suite = "ClickToKnowReuseTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = AppConfig(defaults: defaults, secrets: TestHelpers.InMemorySecretStore())

        XCTAssertTrue(config.reusesQueryHistory, "默认开启复用")
        config.reusesQueryHistory = false
        XCTAssertFalse(config.reusesQueryHistory)
        XCTAssertFalse(AppConfig(defaults: defaults, secrets: TestHelpers.InMemorySecretStore()).reusesQueryHistory, "重启后保留")
    }
}