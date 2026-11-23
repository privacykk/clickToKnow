import Foundation

/// 历史记录筛选条件：来源维度 + 关键词。纯值类型，便于单测与 SwiftUI 绑定。
/// 关键词按空白拆分、忽略大小写，且要求全部命中词条或释义（AND 语义），
/// 例如「helm 包管理」只会留下同时包含两个词的记录。
struct HistoryFilter: Equatable {
    /// 来源维度：全部 / 大模型 / 系统词典。
    /// llm 与 systemDictionary 的 rawValue 与 HistoryEntry.source 的持久化取值一致。
    enum Source: String, CaseIterable, Identifiable {
        case all
        case llm
        case systemDictionary

        var id: String { rawValue }

        /// 筛选条上的文案
        var title: String {
            switch self {
            case .all: return "全部"
            case .llm: return "大模型"
            case .systemDictionary: return "系统词典"
            }
        }

        /// 该来源是否收录此条记录（.all 不做限制）
        func includes(_ entry: HistoryEntry) -> Bool {
            self == .all || entry.source == rawValue
        }
    }

    /// 关键词原文；纯空白视为未填写
    var query: String = ""
    /// 来源筛选
    var source: Source = .all

    /// 是否处于筛选态（关键词或来源任一收窄），空态文案据此区分「无记录」与「无匹配」
    var isActive: Bool {
        source != .all || !keywords.isEmpty
    }

    /// 应用筛选：保持原有新→旧顺序，不做重排
    func apply(to entries: [HistoryEntry]) -> [HistoryEntry] {
        let keywords = keywords
        guard source != .all || !keywords.isEmpty else { return entries }
        return entries.filter { entry in
            guard source.includes(entry) else { return false }
            guard !keywords.isEmpty else { return true }
            let term = entry.term.lowercased()
            let content = entry.content.lowercased()
            return keywords.allSatisfy { term.contains($0) || content.contains($0) }
        }
    }

    /// 拆好的关键词：空白分隔、小写化、去重（避免「a a」这类重复条件）
    private var keywords: [String] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        return Array(Set(tokens))
    }
}
