import Foundation

/// 按配置装配 Provider：有 LLM 配置按所选协议装配客户端，否则用系统词典兜底。
enum ProviderFactory {
    /// 读取 AppConfig.shared 当前配置并实例化对应 Provider；每次调用都新建，配置变更即时生效
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
        case .openAIResponses:
            return OpenAIResponsesProvider(config: endpoint)
        case .anthropic:
            return AnthropicProvider(config: endpoint)
        case .gemini:
            return GeminiProvider(config: endpoint)
        }
    }
}