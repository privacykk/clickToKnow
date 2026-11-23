import XCTest

@testable import ClickToKnow

/// 预设反查与不变量：URL 归一化匹配、Ollama 免密钥唯一性、自定义项空值、协议归属。
final class ProviderPresetsTests: XCTestCase {
    /// 已知端点反查（尾斜杠/大小写不敏感）
    func testMatchingKnownPresetsIgnoresTrailingSlashAndCase() {
        XCTAssertEqual(ProviderPresets.matching(baseURL: "https://api.deepseek.com/")?.id, "deepseek")
        XCTAssertEqual(ProviderPresets.matching(baseURL: "HTTPS://API.MOONSHOT.CN/v1")?.id, "moonshot")
        XCTAssertEqual(
            ProviderPresets.matching(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1")?.id,
            "qwen"
        )
        XCTAssertEqual(
            ProviderPresets.matching(baseURL: "http://localhost:11434/v1")?.id,
            "ollama"
        )
    }

    func testUnknownOrEmptyBaseURLDoesNotMatch() {
        XCTAssertNil(ProviderPresets.matching(baseURL: "https://example.com/v1"))
        XCTAssertNil(ProviderPresets.matching(baseURL: "   "))
        XCTAssertNil(ProviderPresets.matching(baseURL: ""))
    }

    func testOllamaIsTheOnlyKeyOptionalPreset() {
        for preset in ProviderPresets.all {
            XCTAssertEqual(
                preset.apiKeyOptional, preset.id == "ollama",
                "\(preset.id) 的 apiKeyOptional 预期与 ollama 判定一致"
            )
        }
    }

    func testCustomPresetCarriesNoValues() {
        let custom = ProviderPresets.all.first { $0.id == ProviderPresets.customID }
        XCTAssertEqual(custom?.baseURL, "")
        XCTAssertEqual(custom?.suggestedModels, [])
    }

    func testNonCustomPresetsAllHaveBaseURLAndModels() {
        for preset in ProviderPresets.all where preset.id != ProviderPresets.customID {
            XCTAssertFalse(preset.baseURL.isEmpty, "\(preset.id) 缺少 baseURL")
            XCTAssertFalse(preset.suggestedModels.isEmpty, "\(preset.id) 缺少推荐模型")
        }
    }

    /// 协议字段 sanity check：anthropic/gemini 走各自原生协议，其余全部 OpenAI Chat Completions
    func testPresetProtocolsMatchVendor() {
        for preset in ProviderPresets.all {
            let expected: APIProtocol
            switch preset.id {
            case "anthropic": expected = .anthropic
            case "gemini": expected = .gemini
            default: expected = .openAICompatible
            }
            XCTAssertEqual(preset.apiProtocol, expected, "\(preset.id) 的 apiProtocol 不符合预期")
        }
    }
}
