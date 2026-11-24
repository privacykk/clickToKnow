import XCTest

@testable import ClickToKnow

/// 多配置存储：增删改、生效项回退、单配置时代迁移。
/// 每个用例用独立 UserDefaults suite 隔离，不碰真实配置。
final class AppConfigProfilesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secrets: TestHelpers.InMemorySecretStore!
    private var config: AppConfig!

    override func setUp() {
        super.setUp()
        suiteName = "ctk-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = TestHelpers.InMemorySecretStore()
        config = AppConfig(defaults: defaults, secrets: secrets)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// 构造测试 profile（默认 DeepSeek 配置）
    private func makeProfile(
        id: UUID = UUID(),
        apiProtocol: APIProtocol = .openAICompatible,
        baseURL: String = "https://api.deepseek.com",
        model: String = "deepseek-chat"
    ) -> APIProfile {
        APIProfile(id: id, apiProtocol: apiProtocol, baseURL: baseURL, model: model)
    }

    func testUpsertAppendsThenUpdatesInPlace() {
        let profile = makeProfile()
        config.upsertProfile(profile)
        XCTAssertEqual(config.apiProfiles, [profile])

        var updated = profile
        updated.model = "deepseek-reasoner"
        config.upsertProfile(updated)
        XCTAssertEqual(config.apiProfiles, [updated], "同 id 应原地更新而非追加")
    }

    func testActiveProfileFallsBackToFirstWhenIDMissing() {
        let first = makeProfile(model: "m1")
        let second = makeProfile(model: "m2")
        config.upsertProfile(first)
        config.upsertProfile(second)

        XCTAssertEqual(config.activeProfile, first, "未显式选中时回退列表第一项")
        config.activeProfileID = second.id
        XCTAssertEqual(config.activeProfile, second)
        config.activeProfileID = UUID() // 已被删除/损坏的 id
        XCTAssertEqual(config.activeProfile, first, "选中项失效时回退列表第一项")
    }

    func testDeleteProfileReassignsActiveAndRemovesKey() {
        let first = makeProfile(model: "m1")
        let second = makeProfile(model: "m2")
        config.upsertProfile(first)
        config.upsertProfile(second)
        config.activeProfileID = first.id

        config.deleteProfile(id: first.id)
        XCTAssertEqual(config.apiProfiles, [second])
        XCTAssertEqual(config.activeProfileID, second.id, "生效项被删后切到剩余第一项")
    }

    func testEffectiveViewReadsFromActiveProfile() {
        let profile = makeProfile(
            apiProtocol: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-haiku-4-5"
        )
        config.upsertProfile(profile)
        config.activeProfileID = profile.id

        XCTAssertEqual(config.baseURL, "https://api.anthropic.com")
        XCTAssertEqual(config.model, "claude-haiku-4-5")
        XCTAssertEqual(config.apiProtocol, .anthropic)
    }

    /// 单配置时代（baseURL/model/apiProtocol 三个 defaults 键）升级后应迁移为首个 profile 并置为生效
    func testLegacySingleConfigMigratesToProfile() {
        defaults.set("https://api.deepseek.com", forKey: "baseURL")
        defaults.set("deepseek-chat", forKey: "model")
        defaults.set("anthropic", forKey: "apiProtocol")

        config.migrateLegacyConfigIfNeeded()

        XCTAssertEqual(config.apiProfiles.count, 1)
        let profile = config.apiProfiles.first
        XCTAssertEqual(profile?.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(profile?.model, "deepseek-chat")
        XCTAssertEqual(profile?.apiProtocol, .anthropic)
        XCTAssertEqual(config.activeProfileID, profile?.id)
        XCTAssertNil(defaults.string(forKey: "baseURL"), "迁移后遗留端点键应移除")
        XCTAssertNil(defaults.string(forKey: "model"))
        XCTAssertNil(defaults.string(forKey: "apiProtocol"))
    }

    /// 迁移幂等：已有配置列表时不再触发单配置迁移
    func testMigrationIsIdempotentWhenProfilesExist() {
        let existing = makeProfile(model: "existing")
        config.upsertProfile(existing)
        defaults.set("https://legacy.example.com", forKey: "baseURL")

        config.migrateLegacyConfigIfNeeded()

        XCTAssertEqual(config.apiProfiles, [existing])
        XCTAssertEqual(defaults.string(forKey: "baseURL"), "https://legacy.example.com",
                       "已有配置列表时不动遗留键")
    }

    func testEmptyLegacyConfigDoesNotCreateProfile() {
        config.migrateLegacyConfigIfNeeded()
        XCTAssertTrue(config.apiProfiles.isEmpty)
        XCTAssertNil(config.activeProfileID)
    }
}
