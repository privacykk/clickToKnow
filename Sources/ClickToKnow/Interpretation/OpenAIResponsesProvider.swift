import Foundation

/// OpenAI Responses API（POST /responses）客户端。
/// 与 Chat Completions 的差异：instructions 是顶层字段（替代 system message），input 可直接为字符串，
/// 响应在 output[] 里按 type 分块（reasoning/message 交错），文本在 message 的 output_text 块中。
final class OpenAIResponsesProvider: InterpretationProvider, LLMPinging {
    typealias Config = LLMEndpointConfig

    private let config: Config
    private let session: URLSession

    /// session 可注入，便于测试替换为本地 stub
    init(config: Config, session: URLSession = LLMProviderSupport.makeSession()) {
        self.config = config
        self.session = session
    }

    /// 非流式整包（Responses 的 SSE 事件结构不同，暂未做流式；等待感由其通常较快的响应兜底）
    func interpret(_ text: String, context: String?) async throws -> Interpretation {
        let body: [String: Any] = [
            "model": config.model,
            "instructions": LLMProviderSupport.systemPrompt,
            "input": LLMProviderSupport.userPrompt(term: text, context: context),
            "temperature": 0.2,
            "stream": false
        ]
        let data = try await send(body: body, timeout: nil)

        let decoded: ResponsesReply
        do {
            decoded = try JSONDecoder().decode(ResponsesReply.self, from: data)
        } catch {
            throw InterpretationError.badResponse
        }
        // output 里可能混有 reasoning 项，取第一个 message 项的第一段 output_text
        let raw = decoded.output
            .first { $0.type == "message" }?
            .content?.first { $0.type == "output_text" }?
            .text
        guard let raw, !raw.isEmpty else {
            throw InterpretationError.badResponse
        }
        return Interpretation(
            term: text,
            content: LLMProviderSupport.stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            source: .llm
        )
    }

    /// 最小连通探测：最小输出上限压到 16（Responses 对推理模型要求 max_output_tokens ≥ 16）。
    func ping() async throws -> TimeInterval {
        let body: [String: Any] = [
            "model": config.model,
            "input": "hi",
            "max_output_tokens": 16,
            "stream": false
        ]
        let start = Date()
        _ = try await send(body: body, timeout: 15) // 测试不应久等：15s < session 的 20s
        return Date().timeIntervalSince(start)
    }

    /// 发送请求并做过错归类；timeout 传 nil 用 session 默认（20s），ping 显式压到 15s
    private func send(body: [String: Any], timeout: TimeInterval?) async throws -> Data {
        guard let url = responsesURL else {
            throw InterpretationError.badConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    /// 端点拼接：剥尾部斜杠后追加 /responses；无 scheme 视为非法配置
    private var responsesURL: URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else { return nil }
        return URL(string: base + "/responses")
    }

    /// Responses 响应模型：output[] 按 type 分块，正文取 message 项的 output_text
    private struct ResponsesReply: Decodable {
        struct Item: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let type: String
            let content: [Content]?
        }
        let output: [Item]
    }
}
