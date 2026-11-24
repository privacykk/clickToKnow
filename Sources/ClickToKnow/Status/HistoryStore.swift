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
///
/// 写入是后台串行 + 合并的：500 条记录整体编码 + 原子落盘放在主线程上是每次查询都要付的卡顿，
/// 而连续查询/删除只需要落盘「最新状态」，中间态没有保存价值。
/// 内存的 `entries` 仍在主线程维护（UI 直接读，无需加锁）。
@MainActor
final class HistoryStore {
    static let shared = HistoryStore()

    /// 记录变更通知（新增 / 单条删除 / 清空）：历史窗口常驻时据此实时刷新列表
    static let didChangeNotification = Notification.Name("ClickToKnowHistoryDidChange")

    /// 历史记录文件路径（Application Support/ClickToKnow/history.json）
    private let fileURL: URL
    /// 条目上限，超出淘汰最旧
    private let capacity = 500
    /// 后台写入器（合并写，不阻塞主线程）
    private let writer: HistoryFileWriter

    /// 内存中的全部记录（新 → 旧）
    private(set) var entries: [HistoryEntry] = []
    /// 启动加载时遇到的问题（如原文件损坏已备份）：历史窗口顶部据此提示，避免静默丢数据
    private(set) var loadWarning: String?

    /// directory 可注入（单测用临时目录，避免污染真实数据）
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClickToKnow", isDirectory: true)
        fileURL = dir.appendingPathComponent("history.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writer = HistoryFileWriter(fileURL: fileURL)
        let loaded = Self.load(from: fileURL)
        entries = loaded.entries
        loadWarning = loaded.warning
    }

    /// 追加一条记录（插到最前）并裁剪到容量上限，随后异步落盘
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

    /// 等待后台写入落盘（退出前与单测用）
    func flush() {
        writer.flush()
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

    /// 提交最新快照给后台写入器（立即返回；失败由写入器记日志）
    private func save() {
        writer.submit(entries)
    }

    /// 从磁盘加载。文件不存在视为「还没有历史」；解析失败则认为文件损坏：
    /// 先把它备份成 history.corrupt-<时间戳>.json 再以空列表启动。
    /// 旧实现是静默返回空数组，于是下一次写入直接把用户原数据覆盖掉——损坏变成永久丢失。
    static func load(from url: URL) -> (entries: [HistoryEntry], warning: String?) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return ([], nil) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return (try decoder.decode([HistoryEntry].self, from: data), nil)
        } catch {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("history.corrupt-\(stamp).json")
            var warning = "历史记录文件无法解析，本次以空列表启动"
            if (try? FileManager.default.moveItem(at: url, to: backup)) != nil {
                warning += "；原文件已备份为 \(backup.lastPathComponent)"
            } else {
                warning += "；原文件备份失败，请手动检查 \(url.path)"
            }
            Log.app.error("历史记录解析失败：\(error.localizedDescription)；\(warning)")
            return ([], warning)
        }
    }
}

/// 历史记录文件写入器：串行后台队列 + 合并写。
/// 同一时刻只保留「最新快照」，连续变更只落盘最后一份，不会为每次中间态都编码一次。
final class HistoryFileWriter: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.clicktoknow.history.write", qos: .utility)
    private let lock = NSLock()
    /// 待写入的最新快照
    private var pending: [HistoryEntry]?
    /// 后台排空任务是否已在跑
    private var workerScheduled = false
    /// 写失败回调（可注入，便于断言；生产写日志）
    private let onError: @Sendable (String) -> Void

    init(fileURL: URL, onError: @escaping @Sendable (String) -> Void = { message in
        Log.app.error("历史记录写入失败：\(message)")
    }) {
        self.fileURL = fileURL
        self.onError = onError
    }

    /// 提交最新快照（立即返回）
    func submit(_ entries: [HistoryEntry]) {
        lock.lock()
        pending = entries
        let shouldStart = !workerScheduled
        workerScheduled = true
        lock.unlock()
        guard shouldStart else { return }
        queue.async { [self] in
            drain()
        }
    }

    /// 等待队列中已有写入全部完成
    func flush() {
        queue.sync {}
    }

    /// 排空循环：每轮取走最新快照写入，期间又有新提交则继续下一轮
    private func drain() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                workerScheduled = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            write(snapshot)
        }
    }

    /// 原子写盘：日期用 ISO 8601，失败回调上报（下次写入会重试）
    private func write(_ entries: [HistoryEntry]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            onError(error.localizedDescription)
        }
    }
}
