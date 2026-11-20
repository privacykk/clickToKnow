import Foundation

/// 各协议 Provider 共用的支撑件：session 工厂、网络错误翻译、系统提示词、响应清洗。
enum LLMProviderSupport {
    /// 自建 session 而非复用 URLSession.shared：shared 默认超时 60s，
    /// 卡住时悬浮窗会长时间无响应；这里把请求超时压到 20s。
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }

    /// 把 URLError 翻译成人能看懂的话；timeoutSeconds 与调用方请求超时一致（ping 为 15s，interpret 为 20s）
    static func networkHint(_ error: URLError, timeoutSeconds: Int = 20) -> String {
        switch error.code {
        case .timedOut: return "请求超时（\(timeoutSeconds)s），请检查网络或稍后重试"
        case .cannotFindHost: return "找不到主机，请检查 Base URL"
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return "无法连接服务，请检查网络或 Base URL"
        default: return error.localizedDescription
        }
    }

    /// 非 2xx 时保留响应体片段：401/402 等的 code、message 字段是定位问题的关键
    static func serverError(status: Int, data: Data) -> InterpretationError {
        let snippet = String(decoding: data.prefix(240), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .server("HTTP \(status) \(snippet)")
    }

    /// 兜底：模型偶尔无视指令仍包一层 ```markdown 围栏，剥掉以免显示噪音。
    static func stripCodeFence(_ text: String) -> String {
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

    /// 用户消息：词条 + 可选的选区前后文（AX 直读路径提供）。
    /// 上下文是领域判断的关键素材——「helm」出现在 K8s 段落里应判为包管理器而非"舵"。
    static func userPrompt(term: String, context: String?) -> String {
        var prompt = "请解释这个词：\"\(term)\""
        if let context, !context.isEmpty {
            prompt += "\n\n上下文（选区前后文，据此判断该词的技术领域）：\n\"\"\"\n\(context)\n\"\"\""
        }
        return prompt
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
