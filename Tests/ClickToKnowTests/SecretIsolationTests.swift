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

    func test_savingChangedEndpointDoesNotReuseStoredKey() {
        let config = makeConfig()
        let original = config.upsertProfile(makeProfile())
        XCTAssertTrue(config.setAPIKey("test-old-key", for: original))
        let sameHost = makeProfile(id: original.id, baseURL: "https://api.deepseek.com/v1")
        XCTAssertEqual(config.saveEditedProfile(sameHost), .saved(sameHost))
        XCTAssertNotNil(config.storedKeyMask(for: sameHost))
        let differentHost = makeProfile(id: original.id, baseURL: "https://different.example/v1")
        guard case .saved(let replacement) = config.saveEditedProfile(differentHost) else {
            return XCTFail("未保存新端点")
        }
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(config.activeProfile?.baseURL, differentHost.baseURL)
        XCTAssertNil(config.storedKeyMask(for: replacement))
    }

    func test_failedKeyReplacementLeavesOldEndpointAndKeyUsable() {
        let config = makeConfig()
        let original = config.upsertProfile(makeProfile())
        XCTAssertTrue(config.setAPIKey("old-key", for: original))
        let edited = makeProfile(id: original.id, baseURL: "https://different.example/v1")
        secrets.failSaves = true
        XCTAssertEqual(config.saveEditedProfile(edited, key: "new-key"), .keyNotSaved)
        XCTAssertEqual(config.activeProfile, original)
        XCTAssertEqual(config.apiKey, "old-key")
        guard case .saved(let replacement) = config.saveEditedProfile(edited, key: "new-key", sessionOnly: true) else {
            return XCTFail("未保存会话密钥")
        }
        XCTAssertNotEqual(replacement.id, original.id)
        XCTAssertEqual(config.activeProfile, replacement)
        XCTAssertEqual(config.apiKey, "new-key")
        XCTAssertEqual(makeConfig().apiKey, "")
    }

    func test_failedSaveRequiresExplicitSessionChoiceAndDoesNotPersistKey() {
        let profileA = makeProfile(baseURL: "https://api.deepseek.com")
        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")
        let config = makeConfig()
        config.upsertProfile(profileA)
        config.upsertProfile(profileB)

        config.activeProfileID = profileA.id
        secrets.failSaves = true
        XCTAssertEqual(config.saveEditedProfile(profileA, key: "sk-aaaa-secret-a"), .keyNotSaved)
        XCTAssertNil(defaults.string(forKey: "apiKey"))
        XCTAssertEqual(config.apiKeySource, .none)

        XCTAssertEqual(config.saveEditedProfile(profileA, key: "sk-aaaa-secret-a", sessionOnly: true), .saved(profileA))
        XCTAssertEqual(config.apiKeySource, .session)
        XCTAssertEqual(config.effectiveAPIKey(for: profileA), "sk-aaaa-secret-a")

        // 切到 B：B 不得继承这份明文
        config.activeProfileID = profileB.id
        XCTAssertEqual(config.effectiveAPIKey(for: profileB), "", "B 不得借用 A 的会话密钥")
        XCTAssertEqual(config.apiKey, "", "生效配置 B 的 apiKey 必须为空")
        XCTAssertEqual(config.apiKeySource, .none)
        XCTAssertNil(config.storedKeyMask(for: profileB), "B 不应回显 A 的密钥掩码")

        // A 再切回来仍可用
        config.activeProfileID = profileA.id
        XCTAssertEqual(config.effectiveAPIKey(for: profileA), "sk-aaaa-secret-a")
        XCTAssertEqual(config.apiKeySource, .session)
        XCTAssertEqual(makeConfig().apiKeySource, .none)
        XCTAssertNil(defaults.string(forKey: "apiKey"))
    }

    func test_lockedKeyDoesNotPromptUntilExplicitAuthorizationAndCanRetry() {
        let config = makeConfig()
        let profile = config.upsertProfile(makeProfile())
        let account = AppConfig.keychainAccount(for: profile.id)
        secrets.storage[account] = "test-locked-key"
        secrets.lockedAccounts = [account]
        config.migrateLegacyConfigIfNeeded()

        XCTAssertEqual(config.apiKeySource, .keychainNeedsAuthorization)
        XCTAssertEqual(config.llmStatus, .missingKey)
        XCTAssertNil(config.storedKeyMask(for: profile))
        XCTAssertFalse(ProviderFactory.snapshot(from: config).usesLLM)
        XCTAssertTrue(secrets.interactiveReads.isEmpty)
        XCTAssertTrue(secrets.savedAccounts.isEmpty)

        secrets.grantInteraction = false
        XCTAssertFalse(config.authorizeAPIKey(for: profile))
        XCTAssertEqual(config.apiKeySource, .keychainNeedsAuthorization)
        secrets.grantInteraction = true
        XCTAssertTrue(config.authorizeAPIKey(for: profile))
        XCTAssertEqual(config.apiKeySource, .keychain)
        XCTAssertTrue(ProviderFactory.snapshot(from: config).usesLLM)
        XCTAssertEqual(secrets.interactiveReads, [account, account])
    }

    /// 重启迁移不得把遗留明文迁到「新的生效配置」名下：
    /// 归属 A 的明文在 restart 时若 B 生效，B 拿不到，A 也不因此丢密钥。
    func test_migrationDoesNotReassignOwnedPlaintextToNewActiveProfile() {
        let profileA = makeProfile()
        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")

        // 模拟旧版本写入的明文及其归属。
        let first = makeConfig()
        first.upsertProfile(profileA)
        first.activeProfileID = profileA.id
        seedLegacyPlaintext(for: profileA)

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
        seedLegacyPlaintext(for: profileA)

        // 重启只整理归属，用户主动操作后才迁移密钥。
        first.activeProfileID = profileB.id
        secrets.failSaves = false
        let second = makeConfig()
        second.migrateLegacyConfigIfNeeded()
        XCTAssertTrue(secrets.savedAccounts.isEmpty)
        XCTAssertTrue(secrets.interactiveReads.isEmpty)
        XCTAssertTrue(second.authorizeAPIKey(for: profileA))

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
        seedLegacyPlaintext(for: profileA)
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
        seedLegacyPlaintext(for: profile)

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
        // upsert 只绑定归属。授权后迁入 A 自己的条目。
        XCTAssertEqual(config.effectiveAPIKey(for: profileA), "sk-legacy-keychain")
        XCTAssertNotNil(secrets.storage["apiKey"])
        XCTAssertTrue(config.authorizeAPIKey(for: profileA))
        XCTAssertNil(secrets.storage["apiKey"], "迁移后遗留 account 应清除")

        let profileB = makeProfile(baseURL: "https://api.moonshot.cn/v1", model: "moonshot-v1-8k")
        config.upsertProfile(profileB)
        XCTAssertEqual(config.effectiveAPIKey(for: profileB), "")
    }

    private func seedLegacyPlaintext(for profile: APIProfile) {
        defaults.set("sk-aaaa-secret-a", forKey: "apiKey")
        defaults.set(profile.id.uuidString, forKey: "legacyAPIKeyOwnerProfileID")
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
