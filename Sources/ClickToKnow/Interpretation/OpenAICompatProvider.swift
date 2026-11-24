import Foundation

/// OpenAI 兼容的 chat/completions 客户端。
/// 通过 baseURL 可对接通义千问（DashScope 兼容模式）、DeepSeek、月之暗面、智谱、Ollama 等。
/// 支持 SSE 流式输出：弹窗边收边渲染，消除长释义的数秒白屏。
final class OpenAICompatProvider: StreamingInterpretationProvider, LLMPinging {
    typealias Config = LLMEndpointConfig

    private let config: Config
    private let session: URLSession

    /// session 可注入，便于测试替换为本地 stub
    init(config: Config, session: URLSession = LLMProviderSupport.makeSession()) {
        self.config = config
        self.session = session
    }

    /// 非流式整包路径：保留给不支持/关闭流式的场景（连接测试走 ping，不经过这里）
    func interpret(_ text: String, context: String?) async throws -> Interpretation {
        let request = try makeChatRequest(text: text, context: context, stream: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw LLMProviderSupport.networkError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw InterpretationError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LLMProviderSupport.serverError(status: http.statusCode, data: data)
        }

        let decoded: ChatResponse
        do {
            decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw InterpretationError.badResponse
        }
        guard let raw = decoded.choices.first?.message.content, !raw.isEmpty else {
            throw InterpretationError.badResponse
        }
        return Self.makeResult(term: text, raw: raw)
    }

    /// 流式路径：SSE 逐行解析 `data: {...}`，每个增量回调累积正文给 UI 渲染。
    /// onDelta 在主 actor 调用；任务取消（关弹窗/新查询）时 URLSession 抛 CancellationError 断连。
    func interpretStreaming(
        _ text: String,
        context: String?,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> Interpretation {
        let request = try makeChatRequest(text: text, context: context, stream: true)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let urlError as URLError {
            throw LLMProviderSupport.networkError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw InterpretationError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            // 非 2xx 时收集错误响应体：状态码 + 片段是定位 401/404 的关键
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte) }
            throw LLMProviderSupport.serverError(status: http.statusCode, data: errorData)
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let jsonData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: jsonData),
                  let piece = chunk.choices.first?.delta.content else { continue }
            accumulated += piece
            await onDelta(accumulated)
        }
        guard !accumulated.isEmpty else {
            throw InterpretationError.badResponse
        }
        return Self.makeResult(term: text, raw: accumulated)
    }

    /// 统一收尾：清洗并封装为释义结果（流式/非流式共用）
    private static func makeResult(term: String, raw: String) -> Interpretation {
        Interpretation(
            term: term,
            content: LLMProviderSupport.stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            source: .llm
        )
    }

    /// 构造 chat/completions 请求：Bearer 鉴权，system + user 两条消息，stream 按路径开关
    private func makeChatRequest(text: String, context: String?, stream: Bool) throws -> URLRequest {
        guard let url = chatCompletionsURL else {
            throw InterpretationError.badConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "stream": stream,
            "messages": [
                ["role": "system", "content": LLMProviderSupport.systemPrompt],
                ["role": "user", "content": LLMProviderSupport.userPrompt(term: text, context: context)]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 最小连通探测：max_tokens=1 的一次对话，验证 baseURL/密钥/模型名三件套。
    /// 成功返回耗时；失败抛 InterpretationError（网络错误已翻译为中文提示）。
    func ping() async throws -> TimeInterval {
        guard let url = chatCompletionsURL else {
            throw InterpretationError.badConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15 // 测试不应久等：15s < session 的 20s
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1,
            "stream": false,
            "messages": [["role": "user", "content": "hi"]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw LLMProviderSupport.networkError(urlError, timeoutSeconds: 15)
        }
        let latency = Date().timeIntervalSince(start)

        guard let http = response as? HTTPURLResponse else {
            throw InterpretationError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LLMProviderSupport.serverError(status: http.statusCode, data: data)
        }
        return latency
    }

    /// 端点拼接：剥尾部斜杠后追加 /chat/completions；无 scheme 视为非法配置
    private var chatCompletionsURL: URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else { return nil }
        return URL(string: base + "/chat/completions")
    }

    /// chat/completions 非流式响应模型
    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    /// SSE 增量块：正文在 choices[].delta.content（首块可能是 role，content 为 nil）
    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }
}
