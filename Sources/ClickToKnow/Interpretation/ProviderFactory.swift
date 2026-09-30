import Foundation

/// 按配置装配 Provider：有 LLM 配置用 OpenAI 兼容实现，否则用系统词典兜底。
enum ProviderFactory {
    static func make() -> InterpretationProvider {
        let config = AppConfig.shared
        if config.hasLLMConfig {
            return OpenAICompatProvider(config: .init(
                baseURL: config.baseURL,
                apiKey: config.apiKey,
                model: config.model
            ))
        }
        return SystemDictionaryProvider()
    }
}