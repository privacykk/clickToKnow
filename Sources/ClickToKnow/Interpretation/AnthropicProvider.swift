import Foundation

/// Anthropic 原生 Messages API（POST /v1/messages）客户端。
/// 与 OpenAI 兼容协议的差异：x-api-key + anthropic-version 头鉴权（非 Bearer），
/// system 是顶层字段（非 messages 数组元素），max_tokens 必填，响应取 content[].text。
final class AnthropicProvider: StreamingInterpretationProvider, LLMPinging {
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

    func interpret(_ text: String, context: String?) async throws -> Interpretation {
        let data = try await send(body: queryBody(text, context: context, stream: false), timeout: nil)

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

    func interpretStreaming(
        _ text: String, context: String?, onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> Interpretation {
        let request = try makeRequest(body: queryBody(text, context: context, stream: true), timeout: nil)
        return try await EventStream.interpret(term: text, request: request, session: session, decode: { data in
            let event = try EventStream.decodeJSON(StreamEvent.self, from: data)
            switch event.type {
            case "content_block_start" where event.content_block?.type == "text":
                return .append(event.content_block?.text ?? "")
            case "content_block_delta" where event.delta?.type == "text_delta":
                return .append(event.delta?.text ?? "")
            case "message_stop": return .done()
            case "error": throw InterpretationError.badResponse
            default: return .skip
            }
        }, onDelta: onDelta)
    }

    private func queryBody(_ text: String, context: String?, stream: Bool) -> [String: Any] {
        var body = pingBody(maxTokens: 512)
        body["system"] = config.explanationStyle.prompt
        body["messages"] = [["role": "user", "content": config.explanationStyle.userPrompt(term: text, context: context)]]
        body["temperature"] = 0.2
        if stream { body["stream"] = true }
        return body
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
    private func makeRequest(body: [String: Any], timeout: TimeInterval?) throws -> URLRequest {
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
        return request
    }

    private func send(body: [String: Any], timeout: TimeInterval?) async throws -> Data {
        let request = try makeRequest(body: body, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw LLMProviderSupport.networkError(
                urlError, timeoutSeconds: Int(timeout ?? 20)
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

    private struct StreamEvent: Decodable {
        struct Block: Decodable {
            let type: String?
            let text: String?
        }

        let type: String
        let delta: Block?
        let content_block: Block?
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
