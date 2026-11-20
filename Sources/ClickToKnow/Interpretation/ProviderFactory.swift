import Foundation

/// 按配置装配 Provider：有 LLM 配置按所选协议装配客户端，否则用系统词典兜底。
enum ProviderFactory {
    static func make() -> InterpretationProvider {
        let config = AppConfig.shared
        guard config.hasLLMConfig else { return SystemDictionaryProvider() }
        let endpoint = LLMEndpointConfig(
            baseURL: config.baseURL,
            apiKey: config.apiKey,
            model: config.model
        )
        switch config.apiProtocol {
        case .openAICompatible:
            return OpenAICompatProvider(config: endpoint)
        case .anthropic:
            return AnthropicProvider(config: endpoint)
        }
    }
}