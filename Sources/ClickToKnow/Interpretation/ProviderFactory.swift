import Foundation

/// 按配置装配 Provider：有 LLM 配置按所选协议装配客户端，否则用系统词典兜底。
enum ProviderFactory {
    /// 取当前配置的快照（查询开始时调用一次）。此后本查询不再读 AppConfig，
    /// 避免响应返回时配置已变导致缓存键/历史归属与实际请求不一致。
    static func snapshot(from config: AppConfig = .shared) -> QuerySnapshot {
        let profile = config.activeProfile
        return QuerySnapshot(
            profileID: profile?.id,
            apiProtocol: profile?.apiProtocol ?? .openAICompatible,
            baseURL: profile?.baseURL ?? "",
            model: profile?.model ?? "",
            apiKey: config.effectiveAPIKey(for: profile)
        )
    }

    /// 按快照装配 Provider：快照里已判定走词典时直接返回系统词典实现
    static func make(_ snapshot: QuerySnapshot) -> InterpretationProvider {
        guard snapshot.usesLLM else { return SystemDictionaryProvider() }
        return make(
            endpoint: LLMEndpointConfig(
                baseURL: snapshot.baseURL,
                apiKey: snapshot.apiKey,
                model: snapshot.model
            ),
            apiProtocol: snapshot.apiProtocol
        )
    }

    /// 按协议装配 LLM Provider（设置页连接测试与划词共用同一套装配规则）
    static func make(endpoint: LLMEndpointConfig, apiProtocol: APIProtocol) -> InterpretationProvider {
        switch apiProtocol {
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