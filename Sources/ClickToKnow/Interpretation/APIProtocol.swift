import Foundation

/// LLM 供应商的 API 协议。
/// 绝大多数服务（DeepSeek/通义/智谱/Ollama/LiteLLM 等）走 OpenAI Chat Completions；
/// OpenAI 新推 Responses、Anthropic 与 Gemini 的原生接口各不相同，分别实现。
/// rawValue 一旦发布不得修改（UserDefaults 持久化）；"openAICompatible" 是历史键名，对应 Chat Completions。
enum APIProtocol: String, CaseIterable, Identifiable, Codable {
    /// OpenAI Chat Completions 兼容协议（历史键名，持久化依赖此 rawValue）
    case openAICompatible
    /// OpenAI 新版 Responses API
    case openAIResponses
    /// Anthropic 原生 Messages API
    case anthropic
    /// Google Gemini 原生 API
    case gemini

    var id: String { rawValue }

    /// 设置页展示用的协议名
    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropic: return "Anthropic Messages"
        case .gemini: return "Gemini API"
        }
    }
}

/// 各协议共用的端点三件套配置
struct LLMEndpointConfig {
    var baseURL: String
    var apiKey: String
    var model: String
}

/// 连接测试的最小能力抽象：LLMConnectionTester 面向它编程，不感知具体协议
protocol LLMPinging {
    /// 最小连通探测（验证 baseURL/密钥/模型名三件套），成功返回耗时；失败抛 InterpretationError
    func ping() async throws -> TimeInterval
}
