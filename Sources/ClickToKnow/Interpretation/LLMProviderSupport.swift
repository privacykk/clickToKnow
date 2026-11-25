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

    /// 密钥清洗：剥掉全部空白字符（含换行/Tab）。URLRequest 的 header 值一旦含换行，
    /// CFNetwork 会静默丢弃整个 Authorization 头（服务器侧表现为「没传 key」的 401），
    /// 粘贴密钥时混入的换行必须在构造鉴权头前拦下。API key 本不含合法空白，全剥最稳。
    static func sanitizedAPIKey(_ key: String) -> String {
        key.components(separatedBy: .whitespacesAndNewlines).joined()
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

    /// 网络错误归类（各 Provider 共用）：请求被取消时（关闭弹窗 / 被新查询取代）
    /// URLSession 抛的是 `URLError(.cancelled)` 而非 `CancellationError`，直接归类成服务错误
    /// 会让「关闭弹窗」退化成一次「查询失败」并重新弹窗。这里统一还原成取消语义。
    static func networkError(_ error: URLError, timeoutSeconds: Int = 20) -> Error {
        if error.code == .cancelled { return CancellationError() }
        return InterpretationError.server(networkHint(error, timeoutSeconds: timeoutSeconds))
    }

    /// 端点主机标识（scheme://host:port，小写）。密钥是按端点授权给出去的，
    /// 表单里把 Base URL 改到另一台主机后，已存密钥不应再被自动沿用。
    static func endpointHost(_ rawURL: String) -> String {
        let trimmed = rawURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(), !host.isEmpty else {
            return ""
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    static func sameEndpointHost(_ firstURL: String, _ secondURL: String) -> Bool {
        let firstHost = endpointHost(firstURL)
        return !firstHost.isEmpty && firstHost == endpointHost(secondURL)
    }

    /// 非 2xx 时给出**可展示的错误摘要**：只保留状态码与白名单字段，不透传原始正文。
    ///
    /// 正文直接进 UI / 日志是明确的泄漏面：第三方代理常在错误体里回显请求内容、
    /// Authorization 头或整段输入；按字节截断还会切出半个 UTF-8 字符（显示成替换符）。
    static func serverError(status: Int, data: Data) -> InterpretationError {
        .server(serverDetail(status: status, data: data))
    }

    /// 错误摘要最大字符数（按 Character，不按字节）
    static let serverDetailLimit = 120

    /// 构造「HTTP 状态码 + 清洗后摘要」的详情串
    static func serverDetail(status: Int, data: Data, limit: Int = serverDetailLimit) -> String {
        // 只解开头一段：错误体动辄整页 HTML，没必要全解；解不出的部分随后被清洗掉
        let body = String(decoding: data.prefix(8 * 1024), as: UTF8.self)
        let extracted = extractedMessage(from: body) ?? body
        let cleaned = sanitizeDetail(extracted, limit: limit)
        return cleaned.isEmpty ? "HTTP \(status)" : "HTTP \(status) \(cleaned)"
    }

    /// 从错误响应体里挑可定位问题的结构化字段（OpenAI / Anthropic 风格的 error.message 等）。
    /// 拿不到结构化字段时返回 nil，由调用方退回纯文本清洗。
    static func extractedMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any] else { return nil }

        var parts: [String] = []
        if let error = object["error"] as? [String: Any] {
            for key in ["type", "code", "message"] {
                if let value = error[key] as? String, !value.isEmpty { parts.append(value) }
            }
        } else if let error = object["error"] as? String, !error.isEmpty {
            parts.append(error)
        }
        for key in ["message", "msg", "error_description", "detail"] {
            if let value = object[key] as? String, !value.isEmpty { parts.append(value) }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " / ")
    }

    /// 清洗错误摘要：去控制字符与替换符 → 打码凭证 → 压空白 → 按字符截断
    static func sanitizeDetail(_ text: String, limit: Int) -> String {
        var stripped = ""
        for scalar in text.unicodeScalars {
            if scalar == "\u{FFFD}" { continue } // 容错解码残留的替换符不展示
            if CharacterSet.controlCharacters.contains(scalar) {
                if scalar == "\n" || scalar == "\r" || scalar == "\t" { stripped.append(" ") }
                continue
            }
            stripped.unicodeScalars.append(scalar)
        }
        // 错误页常是整页 HTML：标签留着只会污染提示（NSTextView 不走 HTML 渲染，但没必要展示）
        let detagged = strippingTags(from: redactingSecrets(in: stripped))
        let collapsed = detagged
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// 去掉 HTML/XML 标签（限长匹配，避免病态输入上爆栈）
    private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]{0,2000}>")

    /// 剥离标签，替换为空格以免相邻文字粘连
    static func strippingTags(from text: String) -> String {
        tagPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: " "
        )
    }

    /// 凭证打码：密钥前缀、Bearer 头、超长无分隔串
    private static let secretPatterns: [NSRegularExpression] = [
        // sk-xxx / ghp_xxx / xoxb-xxx 之类
        try! NSRegularExpression(pattern: "(?i)\\b(sk|pk|ghp|gho|ghs|xoxb|xoxp)[-_][A-Za-z0-9_\\-]{6,}"),
        // Authorization: Bearer xxx
        try! NSRegularExpression(pattern: "(?i)\\bbearer\\s+[A-Za-z0-9._\\-]{6,}"),
        // 任意 32 字符以上的无分隔串（Base64 / hex 凭证）
        try! NSRegularExpression(pattern: "\\b[A-Za-z0-9_\\-]{32,}\\b"),
    ]

    /// 把疑似凭证替换成 `***`（宁可多打码，也不让错误体把密钥带进 UI 或日志）
    static func redactingSecrets(in text: String) -> String {
        var result = text
        for pattern in secretPatterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "***"
            )
        }
        return result
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

    /// 系统提示词：约束输出格式（音标/领域/含义/一句话解释/相关术语）、
    /// 篇幅与风格；各协议 Provider 直接复用，保证不同供应商行为一致
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
