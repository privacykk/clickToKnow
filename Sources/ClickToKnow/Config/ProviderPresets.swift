import Foundation

/// 预设的大模型供应商：一键填充 Base URL、API 协议并给出推荐模型。
struct ProviderPreset: Identifiable, Equatable {
    /// 预设稳定标识（如 "deepseek"），「自定义」用 ProviderPresets.customID
    let id: String
    /// UI 上显示的供应商名称
    let name: String
    /// 该供应商官方 API 端点根地址
    let baseURL: String
    /// 推荐填入的模型名（用户可改）
    let suggestedModels: [String]
    /// Ollama 本地服务通常无鉴权，密钥可留空
    let apiKeyOptional: Bool
    /// 该供应商使用的 API 协议（绝大多数为 OpenAI 兼容）
    let apiProtocol: APIProtocol
}

/// 内置预设集合 + Base URL 反查。
enum ProviderPresets {
    /// 「自定义」预设的保留 id；匹配不到任何预设时 UI 落到该项
    static let customID = "custom"

    /// 内置预设列表；末尾固定为「自定义」项（空端点，仅作 UI 占位）
    static let all: [ProviderPreset] = [
        .init(id: "deepseek", name: "DeepSeek",
              baseURL: "https://api.deepseek.com",
              suggestedModels: ["deepseek-chat", "deepseek-reasoner"], apiKeyOptional: false,
              apiProtocol: .openAICompatible),
        .init(id: "qwen", name: "通义千问",
              baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
              suggestedModels: ["qwen-plus", "qwen-turbo", "qwen-max"], apiKeyOptional: false,
              apiProtocol: .openAICompatible),
        .init(id: "moonshot", name: "月之暗面",
              baseURL: "https://api.moonshot.cn/v1",
              suggestedModels: ["moonshot-v1-8k"], apiKeyOptional: false,
              apiProtocol: .openAICompatible),
        .init(id: "zhipu", name: "智谱清言",
              baseURL: "https://open.bigmodel.cn/api/paas/v4",
              suggestedModels: ["glm-4-flash", "glm-4-air"], apiKeyOptional: false,
              apiProtocol: .openAICompatible),
        .init(id: "openai", name: "OpenAI",
              baseURL: "https://api.openai.com/v1",
              suggestedModels: ["gpt-4o-mini"], apiKeyOptional: false,
              apiProtocol: .openAICompatible),
        .init(id: "anthropic", name: "Anthropic",
              baseURL: "https://api.anthropic.com",
              suggestedModels: ["claude-haiku-4-5", "claude-sonnet-4-5"], apiKeyOptional: false,
              apiProtocol: .anthropic),
        .init(id: "gemini", name: "Google Gemini",
              baseURL: "https://generativelanguage.googleapis.com/v1beta",
              suggestedModels: ["gemini-2.5-flash", "gemini-2.5-pro"], apiKeyOptional: false,
              apiProtocol: .gemini),
        .init(id: "ollama", name: "Ollama（本地）",
              baseURL: "http://localhost:11434/v1",
              suggestedModels: ["llama3.1", "qwen2.5"], apiKeyOptional: true,
              apiProtocol: .openAICompatible),
        .init(id: customID, name: "自定义",
              baseURL: "", suggestedModels: [], apiKeyOptional: false,
              apiProtocol: .openAICompatible)
    ]

    /// 反查已存 Base URL 属于哪个预设（忽略首尾空白/尾部斜杠与大小写）；未命中返回 nil（UI 落到「自定义」）。
    static func matching(baseURL: String) -> ProviderPreset? {
        let normalized = baseURL
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        return all.first { $0.id != customID && $0.baseURL.lowercased() == normalized }
    }
}
