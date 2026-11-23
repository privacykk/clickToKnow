import Foundation

/// 一次释义的结果。
struct Interpretation {
    /// 结果来源：系统词典兜底或 LLM
    enum Source: String {
        case systemDictionary
        case llm
    }

    /// 被释义的词（选区文本）
    let term: String
    /// 释义内容：LLM 返回 Markdown，系统词典返回纯文本。
    let content: String
    /// 内容来源，UI 据此决定渲染方式
    let source: Source
}