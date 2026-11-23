import XCTest

@testable import ClickToKnow

/// 应用黑名单：内置密码管理类应用必在其中；用户经 defaults 追加的条目与内置合并生效。
/// 每个用例使用独立 suite，避免污染真实配置。
final class AppConfigBlacklistTests: XCTestCase {
    private let suiteName = "ClickToKnowTests-\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var config: AppConfig!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        config = AppConfig(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        let plistPath = NSHomeDirectory() + "/Library/Preferences/\(suiteName).plist"
        try? FileManager.default.removeItem(atPath: plistPath)
        defaults = nil
        config = nil
        super.tearDown()
    }

    func test_builtInBlacklist_containsPasswordManagers() {
        XCTAssertTrue(AppConfig.builtInBlacklistedBundleIDs.contains("com.1password.1password"))
        XCTAssertTrue(AppConfig.builtInBlacklistedBundleIDs.contains("com.apple.keychainaccess"))
    }

    func test_userAdditions_mergeWithBuiltIn() {
        defaults.set(["com.acme.banking"], forKey: "blacklistedBundleIDs")
        XCTAssertTrue(config.blacklistedBundleIDs.contains("com.acme.banking"))
        XCTAssertTrue(config.blacklistedBundleIDs.contains("com.1password.1password"))
    }

    func test_noUserAdditions_fallsBackToBuiltInOnly() {
        XCTAssertEqual(config.blacklistedBundleIDs, AppConfig.builtInBlacklistedBundleIDs)
    }
}

/// LLM 用户消息构造：无上下文保持原有单行格式（回归），有上下文时附三引号块。
final class LLMUserPromptTests: XCTestCase {
    /// 无上下文：单行格式（旧版本行为回归）
    func test_withoutContext_isSingleLine() {
        let prompt = LLMProviderSupport.userPrompt(term: "helm", context: nil)
        XCTAssertEqual(prompt, "请解释这个词：\"helm\"")
    }

    func test_emptyContext_treatedAsNone() {
        let prompt = LLMProviderSupport.userPrompt(term: "helm", context: "")
        XCTAssertEqual(prompt, "请解释这个词：\"helm\"")
    }

    func test_withContext_appendsQuotedBlock() {
        let prompt = LLMProviderSupport.userPrompt(term: "helm", context: "在 Kubernetes 中安装 chart")
        XCTAssertTrue(prompt.contains("\"helm\""))
        XCTAssertTrue(prompt.contains("在 Kubernetes 中安装 chart"))
        XCTAssertTrue(prompt.contains("\"\"\""))
    }
}
