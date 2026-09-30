import Foundation

/// 释义来源抽象。实现方可替换（系统词典兜底 / OpenAI 兼容 LLM）。
protocol InterpretationProvider {
    func interpret(_ text: String) async throws -> Interpretation
}

enum InterpretationError: Error {
    case notFound
    case badResponse
    case badConfiguration
}