import Foundation

/// OpenAI 兼容的 chat/completions 客户端。
/// 通过 baseURL 可对接通义千问（DashScope 兼容模式）、DeepSeek、月之暗面、智谱、Ollama 等。
final class OpenAICompatProvider: InterpretationProvider {
    struct Config {
        var baseURL: String
        var apiKey: String
        var model: String
    }

    private let config: Config
    private let session: URLSession

    init(config: Config, session: URLSession = OpenAICompatProvider.makeSession()) {
        self.config = config
        self.session = session
    }

    /// 自建 session 而非复用 URLSession.shared：shared 默认超时 60s，
    /// 卡住时悬浮窗会长时间无响应；这里把请求超时压到 20s。
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }

    func interpret(_ text: String) async throws -> Interpretation {
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
            "stream": false,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": "请解释这个词：\"\(text)\""]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw InterpretationError.server(Self.networkHint(urlError))
        }

        guard let http = response as? HTTPURLResponse else {
            throw InterpretationError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            // 保留响应体片段：401/402 等的 code、message 字段是定位问题的关键
            let snippet = String(decoding: data.prefix(240), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InterpretationError.server("HTTP \(http.statusCode) \(snippet)")
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
        return Interpretation(
            term: text,
            content: Self.stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
            source: .llm
        )
    }

    private var chatCompletionsURL: URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else { return nil }
        return URL(string: base + "/chat/completions")
    }

    /// 把 URLError 翻译成人能看懂的话。
    private static func networkHint(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: return "请求超时（20s），请检查网络或稍后重试"
        case .cannotFindHost: return "找不到主机，请检查 Base URL"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return "无法连接服务，请检查网络或 Base URL"
        default: return error.localizedDescription
        }
    }

    /// 兜底：模型偶尔无视指令仍包一层 ```markdown 围栏，剥掉以免显示噪音。
    private static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var result = text.dropFirst(3)
        if let newline = result.firstIndex(of: "\n") {
            result = result[result.index(after: newline)...]
        }
        if result.hasSuffix("```") {
            result = result.dropLast(3)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }

    static let systemPrompt = """
    你是技术文档领域的专家。用户正在阅读技术文章/网页，遇到陌生词汇时选中它来问你。
    先判断词条语言：英文单词（含缩写）第一行给出 **音标**（IPA，如 /hɛlm/）；中文词条第一行给出 **拼音**（如 fùzài jūnhéng）。
    再判断该词所属的技术领域（如 Kubernetes/云原生、阿里云运维、前端、数据库、算法、网络等），
    并用 Markdown 简洁回答：
    - **音标/拼音**：…（按词条语言二选一）
    - **领域**：…
    - **含义**：（优先给领域术语义，而非字面义；例如 helm 在容器语境是 Kubernetes 的包管理器，不是"舵"）
    - **一句话解释**：…
    - **相关术语**：0-2 个
    控制在 150 字以内，直接回答，不要寒暄，不要重复用户输入，不要用代码围栏包裹。
    """
}
