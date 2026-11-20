import Foundation

/// 面向设置页的连接测试门面：输入表单当前值，输出可直接展示的分类结果。
/// 走最小 chat/completions 对话而非 GET /models：能同时验证模型名可访问（最常见的配置错误）。
struct LLMConnectionTester {
    enum Result: Equatable {
        case success(latencyMs: Int)
        case failure(reason: String)
    }

    private let makeProvider: (LLMEndpointConfig, APIProtocol) -> any LLMPinging

    /// makeProvider 可注入，单测借此替换为 URLProtocol mock 的 session
    init(makeProvider: @escaping (LLMEndpointConfig, APIProtocol) -> any LLMPinging = { config, apiProtocol in
        switch apiProtocol {
        case .openAICompatible: return OpenAICompatProvider(config: config)
        case .anthropic: return AnthropicProvider(config: config)
        }
    }) {
        self.makeProvider = makeProvider
    }

    /// apiKey 传空时自动代入当前生效密钥（环境变量/钥匙串），与实际划词行为保持一致。
    func test(baseURL: String, apiKey: String, model: String,
              apiProtocol: APIProtocol = .openAICompatible) async -> Result {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard !trimmedURL.isEmpty, !trimmedModel.isEmpty else {
            return .failure(reason: "请先填写 Base URL 与 Model")
        }
        let effectiveKey = apiKey.isEmpty ? AppConfig.shared.apiKey : apiKey
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
