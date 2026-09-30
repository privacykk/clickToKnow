import Foundation

/// 一次释义的结果。
struct Interpretation {
    enum Source: String {
        case systemDictionary
        case llm
    }

    let term: String
    /// 释义内容：LLM 返回 Markdown，系统词典返回纯文本。
    let content: String
    let source: Source
}