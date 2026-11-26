import Foundation

/// 一条查询记录（生词本条目）。
struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// 被查询的词条
    let term: String
    /// 释义正文（Markdown 或纯文本）
    let content: String
    /// "llm" / "systemDictionary"（Interpretation.Source.rawValue）
    let source: String
    /// 查询时生效的模型名；系统词典兜底为 nil
    let model: String?
    /// 查询时间
    let date: Date
    var favorite: Bool?
    /// 查询指纹（不含密钥的条件摘要）。旧 JSON 迁移来的记录没有指纹：只能浏览，不参与自动复用
    var fingerprint: String?
    var isFavorite: Bool { favorite == true }

    /// date/id 缺省自动生成，常规写入无需关心
    init(
        term: String, content: String, source: String, model: String?,
        date: Date = Date(), id: UUID = UUID(), favorite: Bool? = nil, fingerprint: String? = nil
    ) {
        self.id = id
        self.term = term
        self.content = content
        self.source = source
        self.model = model
        self.date = date
        self.favorite = favorite
        self.fingerprint = fingerprint
    }
}