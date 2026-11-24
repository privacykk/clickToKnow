import Foundation

/// 面向设置页的连接测试门面：输入表单当前值，输出可直接展示的分类结果。
/// 走最小 chat/completions 对话而非 GET /models：能同时验证模型名可访问（最常见的配置错误）。
struct LLMConnectionTester {
    /// 测试结果：成功带毫秒延迟；失败带可直接展示的中文原因
    enum Result: Equatable {
        case success(latencyMs: Int)
        case failure(reason: String)
    }

    /// Provider 工厂闭包（可注入替换以便单测）
    private let makeProvider: (LLMEndpointConfig, APIProtocol) -> any LLMPinging

    /// makeProvider 可注入，单测借此替换为 URLProtocol mock 的 session
    init(makeProvider: @escaping (LLMEndpointConfig, APIProtocol) -> any LLMPinging = { config, apiProtocol in
        switch apiProtocol {
        case .openAICompatible: return OpenAICompatProvider(config: config)
        case .openAIResponses: return OpenAIResponsesProvider(config: config)
        case .anthropic: return AnthropicProvider(config: config)
        case .gemini: return GeminiProvider(config: config)
        }
    }) {
        self.makeProvider = makeProvider
    }

    /// 只测表单给什么就用什么：不再在 key 为空时自动代入当前生效配置的密钥。
    /// 那层隐式回退正是「新增配置借用 A 的密钥发往 B」的来源之一——
    /// 表单端点已经换掉、密钥却还是别的配置的，测试通过与实际划词行为也不一致。
    func test(baseURL: String, apiKey: String, model: String,
              apiProtocol: APIProtocol = .openAICompatible) async -> Result {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty, !trimmedModel.isEmpty else {
            return .failure(reason: "请先填写 Base URL 与 Model")
        }
        // 环境变量/.env 是全局生效的密钥来源（不是某个配置的私钥），可以代入；其余一律不借用
        let environmentKey = ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? ""
        let effectiveKey = apiKey.isEmpty ? environmentKey : apiKey
        let provider = makeProvider(
            .init(baseURL: trimmedURL, apiKey: effectiveKey, model: trimmedModel),
            apiProtocol
        )
        do {
            let latency = try await provider.ping()
            return .success(latencyMs: Int(latency * 1000))
        } catch {
            return .failure(reason: Self.classify(error))
        }
    }

    /// 高频 HTTP 状态码加友好前缀，其余复用 InterpretationError 既有中文文案（networkHint 口径）
    private static func classify(_ error: Error) -> String {
        guard let interpretation = error as? InterpretationError else {
            return error.localizedDescription
        }
        if case .server(let detail) = interpretation {
            if detail.hasPrefix("HTTP 401") || detail.hasPrefix("HTTP 403") {
                return "密钥无效或无权限（\(detail)）"
            }
            if detail.hasPrefix("HTTP 404") {
                return "模型或路径不存在（\(detail)）"
            }
            return detail
        }
        return interpretation.userMessage
    }
}
