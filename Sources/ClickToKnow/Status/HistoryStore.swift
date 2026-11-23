import Foundation

/// 一条查询记录（生词本条目）。
struct HistoryEntry: Codable, Equatable, Identifiable {
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

    /// date/id 缺省自动生成，常规写入无需关心
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

    /// 记录变更通知（新增 / 单条删除 / 清空）：历史窗口常驻时据此实时刷新列表
    static let didChangeNotification = Notification.Name("ClickToKnowHistoryDidChange")

    /// 历史记录文件路径（Application Support/ClickToKnow/history.json）
    private let fileURL: URL
    /// 条目上限，超出淘汰最旧
    private let capacity = 500

    /// 内存中的全部记录（新 → 旧）
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

    /// 追加一条记录（插到最前）并裁剪到容量上限，随后同步落盘
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
        notifyChange()
    }

    /// 删除单条记录（id 不存在时忽略）并落盘
    func remove(id: HistoryEntry.ID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        save()
        notifyChange()
    }

    /// 清空全部记录并落盘
    func removeAll() {
        entries.removeAll()
        save()
        notifyChange()
    }

    // MARK: - 导出

    /// 标准 CSV：字段含逗号/引号/换行时按 RFC 4180 加引号转义。
    /// source 传 nil 导出全部；历史窗口传入当前筛选结果，做到「所见即所得」。
    func exportCSV(_ source: [HistoryEntry]? = nil) -> String {
        var lines = ["term,source,model,date,content"]
        let formatter = ISO8601DateFormatter()
        for entry in source ?? entries {
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

    /// Anki 导入格式：TSV（正面=词条，背面=释义，换行转 <br>）。source 语义同 exportCSV
    func exportAnkiTSV(_ source: [HistoryEntry]? = nil) -> String {
        (source ?? entries).map { entry in
            let front = Self.tsvField(entry.term)
            let back = Self.tsvField(entry.content)
                .replacingOccurrences(of: "\n", with: "<br>")
            return "\(front)\t\(back)"
        }.joined(separator: "\n") + "\n"
    }

    /// CSV 字段转义：含逗号/引号/换行时用双引号包裹，内部引号翻倍
    private static func csvField(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// TSV 字段清洗：制表符替换为空格并去除首尾空白
    private static func tsvField(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 持久化

    /// 广播变更（历史窗口订阅后实时刷新；调用方均在主线程）
    private func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// 原子写盘：日期用 ISO 8601，失败仅记日志（下次写入重试）
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

    /// 从磁盘加载（文件不存在或解析失败返回空数组，不阻断启动）
    private static func load(from url: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }
}
