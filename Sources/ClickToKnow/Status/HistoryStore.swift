import Foundation

/// 一条查询记录（生词本条目）。
struct HistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let term: String
    let content: String
    /// "llm" / "systemDictionary"（Interpretation.Source.rawValue）
    let source: String
    /// 查询时生效的模型名；系统词典兜底为 nil
    let model: String?
    let date: Date

    init(term: String, content: String, source: String, model: String?, date: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.term = term
        self.content = content
        self.source = source
        self.model = model
        self.date = date
    }
}

/// 历史记录持久化：Application Support/ClickToKnow/history.json，新→旧排序，
/// 上限 500 条（超出淘汰最旧）。查询成功即写入；历史窗口负责浏览与导出。
/// 仅在主线程访问（AppDelegate / HistoryView），无需加锁。
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    private let fileURL: URL
    private let capacity = 500

    private(set) var entries: [HistoryEntry] = []

    /// directory 可注入（单测用临时目录，避免污染真实数据）
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClickToKnow", isDirectory: true)
        fileURL = dir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        entries = Self.load(from: fileURL)
    }

    func add(_ interpretation: Interpretation, model: String?) {
        entries.insert(HistoryEntry(
            term: interpretation.term,
            content: interpretation.content,
            source: interpretation.source.rawValue,
            model: model
        ), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    // MARK: - 导出

    /// 标准 CSV：字段含逗号/引号/换行时按 RFC 4180 加引号转义
    func exportCSV() -> String {
        var lines = ["term,source,model,date,content"]
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            let fields = [
                Self.csvField(entry.term),
                entry.source,
                entry.model ?? "",
                formatter.string(from: entry.date),
                Self.csvField(entry.content),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Anki 导入格式：TSV（正面=词条，背面=释义，换行转 <br>）
    func exportAnkiTSV() -> String {
        entries.map { entry in
            let front = Self.tsvField(entry.term)
            let back = Self.tsvField(entry.content)
                .replacingOccurrences(of: "\n", with: "<br>")
            return "\(front)\t\(back)"
        }.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func tsvField(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 持久化

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("历史记录写入失败：\(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }
}
