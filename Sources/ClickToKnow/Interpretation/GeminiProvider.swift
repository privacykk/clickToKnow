import Foundation

/// Gemini 原生 generateContent API（POST /models/{model}:generateContent）客户端。
/// 与 OpenAI 协议的差异：x-goog-api-key 头鉴权、systemInstruction 是顶层字段、
/// 对话内容在 contents[].parts[]，响应取 candidates[0].content.parts[].text。
final class GeminiProvider: StreamingInterpretationProvider, LLMPinging {
    typealias Config = LLMEndpointConfig

    private let config: Config
    private let session: URLSession

    /// session 可注入，便于测试替换为本地 stub
    init(config: Config, session: URLSession = LLMProviderSupport.makeSession()) {
        self.config = config
        self.session = session
    }

    func interpret(_ text: String, context: String?) async throws -> Interpretation {
        let data = try await send(body: queryBody(text, context: context), timeout: nil)

        let decoded: GenerateContentResponse
        do {
            decoded = try JSONDecoder().decode(GenerateContentResponse.self, from: data)
        } catch {
            throw InterpretationError.badResponse
        }
        let raw = decoded.visibleText
        guard !raw.isEmpty else {
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
        let request = try makeRequest(body: queryBody(text, context: context), timeout: nil, stream: true)
        return try await EventStream.interpret(
            term: text, request: request, session: session,
            decode: { data in
                let chunk = try EventStream.decodeJSON(GenerateContentResponse.self, from: data)
                guard chunk.error == nil else { throw InterpretationError.badResponse }
                if let reason = chunk.candidates?.first?.finishReason, reason != "FINISH_REASON_UNSPECIFIED" {
                    guard reason == "STOP" || reason == "MAX_TOKENS" else { throw InterpretationError.badResponse }
                    return .done(chunk.visibleText)
                }
                return .append(chunk.visibleText)
            }, onDelta: onDelta
        )
    }

    private func queryBody(_ text: String, context: String?) -> [String: Any] {
        [
            "systemInstruction": ["parts": [["text": config.explanationStyle.prompt]]],
            "contents": [["role": "user",
                          "parts": [["text": config.explanationStyle.userPrompt(term: text, context: context)]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 512]
        ]
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
    private func makeRequest(body: [String: Any], timeout: TimeInterval?, stream: Bool) throws -> URLRequest {
        guard let url = generateContentURL(stream: stream) else {
            throw InterpretationError.badConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let timeout { request.timeoutInterval = timeout }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func send(body: [String: Any], timeout: TimeInterval?) async throws -> Data {
        let request = try makeRequest(body: body, timeout: timeout, stream: false)
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
    private func generateContentURL(stream: Bool) -> URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else { return nil }
        let model = config.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return nil }
        let action = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        return URL(string: "\(base)/models/\(model):\(action)")
    }

    /// generateContent 响应模型：candidates 可为空（如输出被 MAX_TOKENS 截断）
    private struct GenerateContentResponse: Decodable {
        struct APIError: Decodable { let code: Int? }

        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable {
                    let text: String?
                    let thought: Bool?
                }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        let candidates: [Candidate]?
        let error: APIError?

        var visibleText: String {
            candidates?.first?.content?.parts?.compactMap { $0.thought == true ? nil : $0.text }.joined() ?? ""
        }
    }
}
