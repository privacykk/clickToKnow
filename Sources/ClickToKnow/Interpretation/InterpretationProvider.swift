import Foundation

/// 释义来源抽象。实现方可替换（系统词典兜底 / OpenAI 兼容 LLM / Anthropic）。
/// context 为选区前后文（AX 直读路径提供）：LLM 据此做领域判断，「helm」在 K8s 段落里
/// 是包管理器而非"舵"；⌘C 兜底路径拿不到上下文时传 nil。
protocol InterpretationProvider {
    func interpret(_ text: String, context: String?) async throws -> Interpretation
}

extension InterpretationProvider {
    /// 无上下文便捷入口：保持既有调用方与测试（interpret("helm")）无需改动
    func interpret(_ text: String) async throws -> Interpretation {
        try await interpret(text, context: nil)
    }
}

/// 可选的流式能力：实现方增量回调「累积正文」（非单片增量），
/// AppDelegate 优先走流式让弹窗边收边渲染，消除长释义的数秒白屏。
/// onDelta 保证在主 actor 调用，可直接驱动 UI。
protocol StreamingInterpretationProvider: InterpretationProvider {
    func interpretStreaming(
        _ text: String,
        context: String?,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> Interpretation
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
