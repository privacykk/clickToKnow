import Foundation

/// 释义来源抽象。实现方可替换（系统词典兜底 / OpenAI 兼容 LLM）。
protocol InterpretationProvider {
    func interpret(_ text: String) async throws -> Interpretation
}

enum InterpretationError: Error {
    case notFound
    case badResponse
    case badConfiguration
    /// 服务端返回非 2xx，携带状态码与响应片段便于排查（如 invalid_api_key、余额不足）
    case server(String)

    var userMessage: String {
        switch self {
        case .notFound:
            return "未找到该词的释义"
        case .badResponse:
            return "服务返回内容异常，请重试"
        case .badConfiguration:
            return "配置无效：请检查 Base URL（如 https://api.deepseek.com）"
        case .server(let detail):
            return "服务返回错误：\(detail)"
        }
    }
}
