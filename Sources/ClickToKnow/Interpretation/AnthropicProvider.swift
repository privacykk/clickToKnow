import Foundation

/// Anthropic 原生 Messages API（POST /v1/messages）客户端。
/// 与 OpenAI 兼容协议的差异：x-api-key + anthropic-version 头鉴权（非 Bearer），
/// system 是顶层字段（非 messages 数组元素），max_tokens 必填，响应取 content[].text。
final class AnthropicProvider: InterpretationProvider, LLMPinging {
    typealias Config = LLMEndpointConfig

    /// API 版本头：锁 2023-06-01 这一稳定版本，避免服务端默认版本漂移改变行为
    private static let anthropicVersion = "2023-06-01"

    private let config: Config
    private let session: URLSession

    /// session 可注入，便于测试替换为本地 stub
    init(config: Config, session: URLSession = LLMProviderSupport.makeSession()) {
        self.config = config
        self.session = session
    }

    /// 非流式整包（Anthropic SSE 事件结构不同，暂未做流式；等待感由其通常较快的响应兜底）
    func interpret(_ text: String, context: String?) async throws -> Interpretation {
        var body = pingBody(maxTokens: 512)
        body["system"] = LLMProviderSupport.systemPrompt
        body["messages"] = [["role": "user", "content": LLMProviderSupport.userPrompt(term: text, context: context)]]
        body["temperature"] = 0.2

        let data = try await send(body: body, timeout: nil)

        let decoded: MessagesResponse
        do {
            decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw InterpretationError.badResponse
        }
        guard let raw = decoded.content.first(where: { $0.type == "text" })?.text, !raw.isEmpty else {
            throw InterpretationError.badResponse
        }
        return Interpretation(
            term: text,
            content: LLMProviderSupport.stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            source: .llm
        )
    }

    /// 最小连通探测：max_tokens=1 的一次对话，验证 baseURL/密钥/模型名三件套。
    func ping() async throws -> TimeInterval {
        let start = Date()
        _ = try await send(body: pingBody(maxTokens: 1), timeout: 15) // 测试不应久等：15s < session 的 20s
        return Date().timeIntervalSince(start)
    }

    /// 构造探测/对话请求体（max_tokens 按用途传入）
    private func pingBody(maxTokens: Int) -> [String: Any] {
        [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": "hi"]]
        ]
    }

    /// 发送请求并做过错归类；timeout 传 nil 用 session 默认（20s），ping 显式压到 15s
    private func send(body: [String: Any], timeout: TimeInterval?) async throws -> Data {
        guard let url = messagesURL else {
            throw InterpretationError.badConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw InterpretationError.server(
                LLMProviderSupport.networkHint(urlError, timeoutSeconds: Int(timeout ?? 20))
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw InterpretationError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LLMProviderSupport.serverError(status: http.statusCode, data: data)
        }
        return data
    }

    /// 端点拼接：剥尾部斜杠后追加 /v1/messages；无 scheme 视为非法配置
    private var messagesURL: URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else { return nil }
        return URL(string: base + "/v1/messages")
    }

    /// Messages API 响应模型：只取需要的 content 文本块
    private struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }
}
