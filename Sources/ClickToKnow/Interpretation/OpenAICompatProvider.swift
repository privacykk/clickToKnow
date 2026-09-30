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

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw InterpretationError.badResponse
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw InterpretationError.badResponse
        }
        return Interpretation(
            term: text,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            source: .llm
        )
    }

    private var chatCompletionsURL: URL? {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + "/chat/completions")
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
    请判断该词所属的技术领域（如 Kubernetes/云原生、阿里云运维、前端、数据库、算法、网络等），
    并用 Markdown 简洁回答：
    - **领域**：…
    - **含义**：（优先给领域术语义，而非字面义；例如 helm 在容器语境是 Kubernetes 的包管理器，不是"舵"）
    - **一句话解释**：…
    - **相关术语**：0-2 个
    直接回答，不要寒暄，不要重复用户输入。
    """
}