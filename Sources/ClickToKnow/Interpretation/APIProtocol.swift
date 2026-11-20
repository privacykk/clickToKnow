import Foundation

/// LLM 供应商的 API 协议。绝大多数服务（DeepSeek/通义/智谱/Ollama/LiteLLM 等）走 OpenAI 兼容协议；
/// Anthropic 原生接口（/v1/messages，x-api-key 鉴权）是主要例外，单独实现。
enum APIProtocol: String, CaseIterable, Identifiable {
    case openAICompatible
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .anthropic: return "Anthropic"
        }
    }
}

/// 两个协议共用的端点三件套配置
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
