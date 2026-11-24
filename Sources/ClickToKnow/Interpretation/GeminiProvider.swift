import Foundation

/// Gemini 原生 generateContent API（POST /models/{model}:generateContent）客户端。
/// 与 OpenAI 协议的差异：x-goog-api-key 头鉴权、systemInstruction 是顶层字段、
/// 对话内容在 contents[].parts[]，响应取 candidates[0].content.parts[].text。
final class GeminiProvider: InterpretationProvider, LLMPinging {
    typealias Config = LLMEndpointConfig

    private let config: Config
    private let session: URLSession

    /// session 可注入，便于测试替换为本地 stub
    init(config: Config, session: URLSession = LLMProviderSupport.makeSession()) {
        self.config = config
        self.session = session
    }

    /// 非流式整包（Gemini 的流式走 :streamGenerateContent + SSE，暂未做；等待感由其通常较快的响应兜底）
    func interpret(_ text: String, context: String?) async throws -> Interpretation {
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": LLMProviderSupport.systemPrompt]]],
            "contents": [["role": "user",
                          "parts": [["text": LLMProviderSupport.userPrompt(term: text, context: context)]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 512]
        ]
        let data = try await send(body: body, timeout: nil)

        let decoded: GenerateContentResponse
        do {
            decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            throw InterpretationError.badResponse
        }
        let raw = decoded.candidates?
            .first?.content.parts
            .compactMap(\.text)
            .joined()
        guard let raw, !raw.isEmpty else {
            throw InterpretationError.badResponse
        }
        return Interpretation(
            term: text,
            content: LLMProviderSupport.stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            source: .llm
        )
    }

    /// 最小连通探测：maxOutputTokens=1。200 即视为三件套有效——
    /// 输出截断（MAX_TOKENS）时 candidates 可能为空，不能按释义口径判 badResponse。
    func ping() async throws -> TimeInterval {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "hi"]]]],
            "generationConfig": ["maxOutputTokens": 1]
        ]
        let start = Date()
        _ = try await send(body: body, timeout: 15) // 测试不应久等：15s < session 的 20s
        return Date().timeIntervalSince(start)
    }

    /// 发送请求并做过错归类；timeout 传 nil 用 session 默认（20s），ping 显式压到 15s
    private func send(body: [String: Any], timeout: TimeInterval?) async throws -> Data {
        guard let url = generateContentURL else {
            throw InterpretationError.badConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
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

    /// 端点拼接：剥尾部斜杠后追加 /models/{model}:generateContent；URL 需对 model 做合法字符校验由 URL(string:) 兜底
    private var generateContentURL: URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else { return nil }
        let model = config.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        return URL(string: "\(base)/models/\(model):generateContent")
    }

    /// generateContent 响应模型：candidates 可为空（如输出被 MAX_TOKENS 截断）
    private struct GenerateContentResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]
            }
            let content: Content
        }
        let candidates: [Candidate]?
    }
}
