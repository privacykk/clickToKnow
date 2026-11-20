import XCTest

@testable import ClickToKnow

/// hasLLMConfig 的判定逻辑（isLLMReady 纯函数版）：覆盖「Ollama 免密钥预设空密钥可用」这一回归点——
/// 历史上 hasLLMConfig 强制 apiKey 非空，导致 Ollama 预设静默回落系统词典。
final class AppConfigLLMReadyTests: XCTestCase {
    private let ollamaURL = "http://localhost:11434/v1"
    private let deepseekURL = "https://api.deepseek.com"

    func test_fullConfig_withKey_isReady() {
        XCTAssertTrue(AppConfig.isLLMReady(baseURL: deepseekURL, apiKey: "sk-x", model: "deepseek-chat"))
    }

    /// 回归：Ollama 预设标注 apiKeyOptional，空密钥必须视为可用
    func test_ollamaPreset_withoutKey_isReady() {
        XCTAssertTrue(AppConfig.isLLMReady(baseURL: ollamaURL, apiKey: "", model: "qwen2.5"))
    }

    /// 预设反查对尾斜杠/大小写/首尾空白不敏感，空密钥判定同样适用
    func test_ollamaPreset_urlVariants_isReady() {
        XCTAssertTrue(AppConfig.isLLMReady(baseURL: "HTTP://LOCALHOST:11434/v1/", apiKey: "", model: "qwen2.5"))
        XCTAssertTrue(AppConfig.isLLMReady(baseURL: "  http://localhost:11434/v1  ", apiKey: "", model: "qwen2.5"))
    }

    /// 需要密钥的供应商：空密钥不可用（回落系统词典是预期行为）
    func test_keyedProvider_withoutKey_notReady() {
        XCTAssertFalse(AppConfig.isLLMReady(baseURL: deepseekURL, apiKey: "", model: "deepseek-chat"))
    }

    /// 自定义 Base URL 即使指向本地，未命中预设时仍需密钥（保守策略，宁缺毋滥）
    func test_customURL_withoutKey_notReady() {
        XCTAssertFalse(AppConfig.isLLMReady(baseURL: "http://192.168.1.10:11434/v1", apiKey: "", model: "qwen2.5"))
    }

    func test_missingBaseURLorModel_notReady() {
        XCTAssertFalse(AppConfig.isLLMReady(baseURL: "", apiKey: "sk-x", model: "deepseek-chat"))
        XCTAssertFalse(AppConfig.isLLMReady(baseURL: deepseekURL, apiKey: "sk-x", model: ""))
        XCTAssertFalse(AppConfig.isLLMReady(baseURL: ollamaURL, apiKey: "", model: ""))
    }
}
