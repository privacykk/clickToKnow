import XCTest

@testable import ClickToKnow

/// 密钥隔离回归测试（评审问题 1 / 问题 2 的验收条件）。
///
/// 两类缺陷的共同触发条件是「钥匙串写入失败」与「切换生效配置」，
/// 用真实钥匙串既不可控也会动到开发者本机数据，因此这里注入 `InMemorySecretStore`。
final class SecretIsolationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secrets: TestHelpers.InMemorySecretStore!

    override func setUp() {
        super.setUp()
        suiteName = "ctk-secret-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = TestHelpers.InMemorySecretStore()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeConfig() -> AppConfig {
        AppConfig(defaults: defaults, secrets: secrets)
    }

    private func makeProfile(
        id: UUID = UUID(),
        baseURL: String = "https://api.deepseek.com",
        model: String = "deepseek-chat"
    ) -> APIProfile {
        APIProfile(id: id, apiProtocol: .openAICompatible, baseURL: baseURL, model: model)
    }

    // MARK: - 问题 2：回退的明文/遗留密钥必须绑定归属配置

    /// 核心回归：A 保存失败（钥匙串不可用，回退明文）→ 切到 B，B 不得读到 A 的密钥。
    /// 之前明文是无主单值，切换生效配置后新配置直接继承，等于把 A 的密钥发给 B 的端点。
    func test_plaintextFallbackDoesNotLeakToOtherProfileAfterSwitch() {
        let profileA = makeProfile(baseURL: "https://api.deepseek.com")
        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")
        let config = makeConfig()
        config.upsertProfile(profileA)
        config.upsertProfile(profileB)

        // A 为生效配置且钥匙串写入失败 → 回退本地明文
        config.activeProfileID = profileA.id
        secrets.failSaves = true
        let savedToKeychain = config.setAPIKey("sk-aaaa-secret-a", for: profileA)
        XCTAssertFalse(savedToKeychain, "钥匙串写入失败应如实返回 false")
        XCTAssertEqual(defaults.string(forKey: "apiKey"), "sk-aaaa-secret-a", "非空密钥应回退到本地明文")

        // A 自己仍能读到（回退值属于它）
        XCTAssertEqual(config.effectiveAPIKey(for: profileA), "sk-aaaa-secret-a")

        // 切到 B：B 不得继承这份明文
        config.activeProfileID = profileB.id
        XCTAssertEqual(config.effectiveAPIKey(for: profileB), "", "B 不得借用 A 回退的明文密钥")
        XCTAssertEqual(config.apiKey, "", "生效配置 B 的 apiKey 必须为空")
        XCTAssertEqual(config.apiKeySource, .none)
        XCTAssertNil(config.storedKeyMask(for: profileB), "B 不应回显 A 的密钥掩码")

        // A 再切回来仍可用
        config.activeProfileID = profileA.id
        XCTAssertEqual(config.effectiveAPIKey(for: profileA), "sk-aaaa-secret-a")
        XCTAssertEqual(config.apiKeySource, .legacyUserDefaults)
    }

    /// 重启迁移不得把遗留明文迁到「新的生效配置」名下：
    /// 归属 A 的明文在 restart 时若 B 生效，B 拿不到，A 也不因此丢密钥。
    func test_migrationDoesNotReassignOwnedPlaintextToNewActiveProfile() {
        let profileA = makeProfile()
        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")

        // 第一次启动：A 生效，保存失败 → 明文绑定 A
        let first = makeConfig()
        first.upsertProfile(profileA)
        first.activeProfileID = profileA.id
        secrets.failSaves = true
        first.setAPIKey("sk-aaaa-secret-a", for: profileA)

        // 用户切到 B 后重启（钥匙串仍然不可用）
        first.upsertProfile(profileB)
        first.activeProfileID = profileB.id
        let second = makeConfig()
        second.migrateLegacyConfigIfNeeded()

        XCTAssertEqual(second.activeProfile?.id, profileB.id)
        XCTAssertEqual(second.apiKey, "", "重启迁移不得把归属 A 的明文迁到当前生效的 B")
        XCTAssertEqual(second.effectiveAPIKey(for: profileA), "sk-aaaa-secret-a",
                       "A 的密钥仍应可用（只是还留在回退存储里）")
    }

    /// 钥匙串恢复可用后，遗留明文迁入的必须是「归属配置」自己的条目
    func test_migrationMovesOwnedLegacyKeyIntoItsOwnProfile() {
        let profileA = makeProfile()
        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")

        let first = makeConfig()
        first.upsertProfile(profileA)
        first.upsertProfile(profileB)
        first.activeProfileID = profileA.id
        secrets.failSaves = true
        first.setAPIKey("sk-aaaa-secret-a", for: profileA)

        // 切到 B 并重启，此时钥匙串可用
        first.activeProfileID = profileB.id
        secrets.failSaves = false
        let second = makeConfig()
        second.migrateLegacyConfigIfNeeded()

        XCTAssertEqual(secrets.storage[AppConfig.keychainAccount(for: profileA.id)], "sk-aaaa-secret-a",
                       "遗留密钥应迁入归属配置 A 的条目")
        XCTAssertNil(secrets.storage[AppConfig.keychainAccount(for: profileB.id)],
                     "不得迁入当前生效配置 B 的条目")
        XCTAssertNil(defaults.string(forKey: "apiKey"), "迁移成功后应清掉明文")
        XCTAssertEqual(second.effectiveAPIKey(for: profileA), "sk-aaaa-secret-a")
        XCTAssertEqual(second.effectiveAPIKey(for: profileB), "")
    }

    /// 归属配置被删除后，遗留存储必须一并清掉，不能变成无主值被下一个配置继承
    func test_deleteProfileClearsOwnedLegacyStorage() {
        let profileA = makeProfile()
        let config = makeConfig()
        config.upsertProfile(profileA)
        config.activeProfileID = profileA.id
        secrets.failSaves = true
        config.setAPIKey("sk-aaaa-secret-a", for: profileA)
        XCTAssertEqual(defaults.string(forKey: "apiKey"), "sk-aaaa-secret-a")

        config.deleteProfile(id: profileA.id)

        XCTAssertNil(defaults.string(forKey: "apiKey"), "归属配置被删后明文必须清除")
        XCTAssertNil(defaults.string(forKey: "legacyAPIKeyOwnerProfileID"), "归属记录应清除")
        XCTAssertEqual(config.apiKey, "")
    }

    /// 归属配置的遗留密钥被清除后，不得复活
    func test_clearAPIKeyClearsOwnedLegacyStorage() {
        let profile = makeProfile()
        let config = makeConfig()
        config.upsertProfile(profile)
        config.activeProfileID = profile.id
        secrets.failSaves = true
        config.setAPIKey("sk-aaaa-secret-a", for: profile)

        XCTAssertTrue(config.clearAPIKey(for: profile))
        XCTAssertNil(defaults.string(forKey: "apiKey"))
        XCTAssertEqual(config.effectiveAPIKey(for: profile), "")

        // 再保存到钥匙串成功，之前那份明文的归属记录不应残留
        secrets.failSaves = false
        XCTAssertTrue(config.setAPIKey("sk-bbbb-secret-b", for: profile))
        XCTAssertEqual(config.effectiveAPIKey(for: profile), "sk-bbbb-secret-b")
        XCTAssertNil(defaults.string(forKey: "apiKey"))
    }

    /// 首个配置出现时收编无主遗留明文（升级自旧版本），且只归给这一个配置
    func test_unownedLegacyKeyIsAdoptedByFirstProfileOnly() {
        defaults.set("sk-legacy-orphan", forKey: "apiKey")
        let config = makeConfig()

        let profileA = makeProfile()
        config.upsertProfile(profileA)
        XCTAssertEqual(config.effectiveAPIKey(for: profileA), "sk-legacy-orphan")

        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")
        config.upsertProfile(profileB)
        XCTAssertEqual(config.effectiveAPIKey(for: profileB), "", "第二个配置不得共享无主遗留密钥")
    }

    /// 旧版本遗留的默认钥匙串 account（无 owner）同样只归首个/生效配置
    func test_legacyKeychainAccountIsOwnedNotGlobal() {
        secrets.storage["apiKey"] = "sk-legacy-keychain"
        let config = makeConfig()

        let profileA = makeProfile()
        config.upsertProfile(profileA)
        // upsert 时收编 → 迁入 A 自己的条目
        XCTAssertEqual(config.effectiveAPIKey(for: profileA), "sk-legacy-keychain")
        XCTAssertNil(secrets.storage["apiKey"], "迁移后遗留 account 应清除")

        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")
        config.upsertProfile(profileB)
        XCTAssertEqual(config.effectiveAPIKey(for: profileB), "")
    }

    // MARK: - 问题 1：新增配置不得借用任何已存密钥

    /// 新增配置（无已存密钥）时，取到的密钥必须为空——设置页据此不发送任何 Authorization
    func test_newProfileDoesNotBorrowActiveProfileKey() {
        let profileA = makeProfile()
        let config = makeConfig()
        config.upsertProfile(profileA)
        config.activeProfileID = profileA.id
        config.setAPIKey("sk-aaaa-secret-a", for: profileA)

        // 表单里新建的 B（尚未保存）与已保存的 B 都应拿不到 A 的密钥
        let draftB = APIProfile(apiProtocol: .openAICompatible,
                                baseURL: "https://third-party.example.com/v1",
                                model: "some-model")
        XCTAssertEqual(config.effectiveAPIKey(for: draftB), "")
        config.upsertProfile(draftB)
        XCTAssertEqual(config.effectiveAPIKey(for: draftB), "")
    }

    /// 测试连接不再对空密钥做隐式回退：传入空密钥就必须以空密钥发起请求
    func test_connectionTesterSendsNoKeyWhenGivenNone() async throws {
        try XCTSkipUnless(
            (ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? "").isEmpty,
            "环境变量提供全局密钥时，测试器按设计会代用它"
        )
        /// 记录实际下发给 Provider 的端点配置
        final class RecordingPing: LLMPinging {
            var captured: [LLMEndpointConfig] = []
            func ping() async throws -> TimeInterval { 0.01 }
        }
        let ping = RecordingPing()
        let tester = LLMConnectionTester(makeProvider: { endpoint, _ in
            ping.captured.append(endpoint)
            return ping
        })

        let result = await tester.test(baseURL: "https://third-party.example.com/v1",
                                       apiKey: "", model: "some-model")
        XCTAssertEqual(result, .success(latencyMs: 10))
        XCTAssertEqual(ping.captured.count, 1)
        XCTAssertEqual(ping.captured.first?.apiKey, "", "空密钥不得被替换成当前生效配置的密钥")
    }

    // MARK: - 端点主机变更时不再沿用已存密钥

    /// endpointHost 用于判断「密钥还能不能沿用到新地址」
    func test_endpointHostNormalization() {
        XCTAssertEqual(LLMProviderSupport.endpointHost("https://api.deepseek.com"), "https://api.deepseek.com")
        XCTAssertEqual(LLMProviderSupport.endpointHost("HTTPS://API.DeepSeek.com/v1"), "https://api.deepseek.com")
        XCTAssertEqual(LLMProviderSupport.endpointHost("  https://api.deepseek.com/  "), "https://api.deepseek.com")
        XCTAssertEqual(LLMProviderSupport.endpointHost("http://localhost:11434/v1"), "http://localhost:11434")
        XCTAssertNotEqual(
            LLMProviderSupport.endpointHost("https://api.deepseek.com"),
            LLMProviderSupport.endpointHost("https://evil.example.com")
        )
        XCTAssertEqual(LLMProviderSupport.endpointHost("not a url"), "")
    }
}