import Foundation

/// 历史保留条数档位。默认 500；更高档位的前提是启动、搜索与写入的基准验证（见迁移方案第 5 节）
enum HistoryRetention {
    static let defaultLimit = 500
    /// 设置页可选档位（顺序即展示顺序）
    static let options = [100, 500, 1_000, 5_000]
    /// 兜底：持久化值损坏时回到默认档
    static func clamped(_ value: Int) -> Int {
        options.contains(value) ? value : defaultLimit
    }
}

/// 历史存储的占用统计（只覆盖历史相关文件，不含设置、密钥与用户导出文件）
struct HistoryStorageStats: Equatable, Sendable {
    var recordCount: Int
    var databaseBytes: Int64
    var backupBytes: Int64
    var backups: [HistoryFiles.Backup]
    var legacyJSONPresent: Bool
}

/// 历史记录（生词本）的 UI 门面。
///
/// 数据落在本机 SQLite（`history.sqlite3`），内存里保留一份新 → 旧的镜像供列表与导出直接读。
/// 所有 SQL、迁移、清理与统计都在后台串行队列执行；主线程只维护镜像与通知，不阻塞取词与设置界面。
/// 首次升级会把旧的 `history.json` 一次性导入（同事务标记），提交后才归档旧文件。
@MainActor
final class HistoryStore {
    static let shared = HistoryStore(retention: { AppConfig.shared.historyRetentionLimit })

    /// 记录变更通知（新增 / 收藏 / 单条删除 / 清空 / 迁移完成）：历史窗口据此刷新
    static let didChangeNotification = Notification.Name("ClickToKnowHistoryDidChange")
    /// 写入失败通知：释义照常显示，但历史没有保存，界面必须如实提示
    static let didFailToSaveNotification = Notification.Name("ClickToKnowHistorySaveFailed")
    /// 记录被删除 / 清空 / 自动裁剪：携带被删记录的查询指纹与 id，
    /// 上层据此淘汰内存缓存、关闭正在展示的「来自本地历史」结果
    static let didRemoveHistoryNotification = Notification.Name("ClickToKnowHistoryDidRemove")

    enum State: Equatable {
        case loading
        case ready
        case blocked(HistoryBlockReason)
    }

    let files: HistoryFiles
    private let database: HistoryDatabase?
    /// 后台串行队列：迁移、写入、清理、统计都在这条队列上执行
    private let worker = DispatchQueue(label: "com.clicktoknow.history.work", qos: .utility)
    /// 保留条数来源（生产读设置，测试注入固定值）
    private let retention: () -> Int
    private var isPreparing = false

    /// 内存镜像（新 → 旧）
    private(set) var entries: [HistoryEntry] = []
    /// 启动 / 写入问题的可见提示（历史窗口顶部横幅）
    private(set) var loadWarning: String?
    private(set) var state: State = .loading
    /// 最近一次写入失败的原因（为空表示正常）
    private(set) var lastSaveError: String?
    /// 查询指纹 → 最新一条可复用记录（只含带指纹的记录，迁移来的旧记录不参与）
    private var reusableByFingerprint: [String: HistoryEntry] = [:]

    /// directory 可注入（单测用临时目录，避免污染真实数据）。
    /// autostart = false 供单测改为同步准备，保证断言确定。
    init(
        directory: URL? = nil,
        retention: @escaping () -> Int = { HistoryRetention.defaultLimit },
        autostart: Bool = true
    ) {
        let directory = directory ?? Self.defaultDirectory()
        files = HistoryFiles(directory: directory)
        self.retention = retention
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            database = try HistoryDatabase(fileURL: files.databaseURL)
        } catch {
            database = nil
            let message = (error as? HistoryDatabaseError)?.localizedDescription ?? error.localizedDescription
            state = .blocked(.unreadable(message: message))
            loadWarning = message
            Log.app.error("历史数据库不可用：\(message)")
        }
        if autostart { beginPreparation() }
    }

    /// 生产环境的默认目录：~/Library/Application Support/ClickToKnow
    static func defaultDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ClickToKnow", isDirectory: true)
    }

    // MARK: - 首次准备与迁移

    /// 打开数据库 → 必要时导入旧 JSON → 读回全部记录。全程后台执行
    private func beginPreparation() {
        guard let database, !isPreparing else { return }
        isPreparing = true
        if state != .ready { state = .loading }
        let migration = HistoryMigration(files: files)
        worker.async { [weak self] in
            let result: Result<HistoryMigration.Output, Error>
            do {
                result = .success(try migration.prepare(database: database))
            } catch {
                result = .failure(error)
            }
            Task { @MainActor [weak self] in
                self?.isPreparing = false
                self?.apply(result)
            }
        }
    }

    /// 迁移失败后重试（原件仍在，不会重复导入已提交的数据）
    func retryPreparation() {
        guard !isPreparing else { return }
        beginPreparation()
    }

    /// 用户显式选择「从空历史开始」：仅当旧文件无法解析时可用，原文件会备份保留。
    /// 由设置页按钮直接触发，操作只有一次改名和一次标记，同步执行即可，避免用户点完看不到结果。
    func startEmptyAfterCorruptLegacy() {
        guard let database else { return }
        let migration = HistoryMigration(files: files)
        do {
            apply(.success(try migration.startEmptyAfterCorrupt(database: database)))
        } catch {
            apply(.failure(error))
        }
    }

    /// 同步完成首次准备（单测与诊断用；生产走后台，不阻塞启动界面）
    func prepareSynchronously() {
        guard let database else { return }
        let migration = HistoryMigration(files: files)
        do {
            apply(.success(try migration.prepare(database: database)))
        } catch {
            apply(.failure(error))
        }
    }

    private func apply(_ result: Result<HistoryMigration.Output, Error>) {
        switch result {
        case .success(let output):
            entries = output.entries
            loadWarning = output.warning
            state = .ready
            notifyChange()
        case .failure(let error):
            // 旧文件解析失败可重试或选择空库；其余（磁盘、权限、结构）统一按迁移失败处理
            let block: HistoryBlockReason
            if let decode = error as? HistoryMigration.LegacyDecodeFailure {
                block = .corruptLegacyJSON(message: decode.message)
            } else {
                let message = error.localizedDescription
                block = .migrationFailed(message: "历史记录初始化失败：\(message)；可重试")
            }
            state = .blocked(block)
            loadWarning = block.message
            Log.app.error("历史记录初始化失败：\(block.message)")
            notifyChange()
        }
    }

    // MARK: - 写入

    /// 追加一条记录（插到最前）并裁剪到保留上限，随后后台提交
    @discardableResult
    func add(_ interpretation: Interpretation, model: String?, fingerprint: String? = nil) -> HistoryEntry.ID {
        let entry = HistoryEntry(
            term: interpretation.term,
            content: interpretation.content,
            source: interpretation.source.rawValue,
            model: model,
            fingerprint: fingerprint
        )
        entries.insert(entry, at: 0)
        let evicted = trimInMemory()
        notifyChange()
        notifyRemoval(evicted)
        let limit = retention()
        persist("保存历史记录") { database in
            _ = try database.insert(entry, limit: limit)
        }
        return entry.id
    }

    @discardableResult
    func toggleFavorite(id: HistoryEntry.ID) -> Bool? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let favorite = !entries[index].isFavorite
        entries[index].favorite = favorite
        notifyChange()
        persist("更新收藏") { database in
            _ = try database.setFavorite(id, favorite: favorite)
        }
        return favorite
    }

    /// 删除单条记录（id 不存在时忽略）并后台提交
    func remove(id: HistoryEntry.ID) {
        guard let removed = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        notifyChange()
        notifyRemoval([removed])
        persist("删除历史记录") { database in
            _ = try database.delete(id)
        }
    }

    /// 清空全部记录并后台提交（迁移标记保留：重启后不会把已删除的数据再导回来）
    func removeAll() {
        let removed = entries
        entries.removeAll()
        notifyChange()
        notifyRemoval(removed)
        persist("清空历史记录") { database in
            try database.deleteAll()
        }
    }

    /// 等待后台队列排空（退出前与单测用）
    func flush() {
        worker.sync {}
    }

    /// 从磁盘重新读取（外部改动或写失败后回滚内存镜像）
    func reload() {
        guard let database else { return }
        worker.async { [weak self] in
            let loaded = try? database.all()
            Task { @MainActor [weak self] in
                guard let self, let loaded else { return }
                self.entries = loaded
                self.notifyChange()
            }
        }
    }

    /// 当前占用统计（记录数、数据库与备份占用、备份清单）。
    /// 记录数取内存镜像（与磁盘同步维护），不在这里同步查库——VACUUM 期间查库会卡住主线程。
    func storageStats() -> HistoryStorageStats {
        HistoryStorageStats(
            recordCount: entries.count,
            databaseBytes: files.databaseBytes(),
            backupBytes: files.backupBytes(),
            backups: files.backups(),
            legacyJSONPresent: files.hasLegacyJSON
        )
    }

    /// 提交后台写入；失败时如实提示并回滚内存镜像（界面不显示「未保存」的假状态）
    private func persist(_ operation: String, _ work: @escaping @Sendable (HistoryDatabase) throws -> Void) {
        guard let database else {
            handleWriteFailure(
                HistoryDatabaseError.openFailed("历史数据库未就绪"), operation: operation
            )
            return
        }
        let wasFailing = lastSaveError != nil
        worker.async { [weak self] in
            do {
                try work(database)
                // 之前失败过：这次成功后清掉错误标记（顶部提示由用户/下次变更刷新）
                if wasFailing {
                    Task { @MainActor [weak self] in self?.lastSaveError = nil }
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.handleWriteFailure(error, operation: operation)
                }
            }
        }
    }

    private func handleWriteFailure(_ error: Error, operation: String) {
        let message = "\(operation)失败：\(error.localizedDescription)"
        lastSaveError = message
        loadWarning = message
        Log.app.error("历史记录\(message)")
        NotificationCenter.default.post(name: Self.didFailToSaveNotification, object: self)
        reload()
    }

    // MARK: - 历史复用

    /// 按查询指纹取最新一条可复用记录。
    /// 只认带指纹的记录：迁移来的旧记录没有足够信息判断条件是否一致，只能浏览。
    func reusableEntry(fingerprint: String) -> HistoryEntry? {
        reusableByFingerprint[fingerprint]
    }

    /// 当前可复用的记录数（设置页与诊断用）
    var reusableEntryCount: Int { reusableByFingerprint.count }

    /// 重建指纹索引：数组新 → 旧，首次出现即最新
    private func refreshReuseIndex() {
        var index: [String: HistoryEntry] = [:]
        for entry in entries {
            guard let fingerprint = entry.fingerprint, index[fingerprint] == nil else { continue }
            index[fingerprint] = entry
        }
        reusableByFingerprint = index
    }

    /// 广播被删记录：上层据此淘汰内存缓存，避免「删了还能命中」
    private func notifyRemoval(_ removed: [HistoryEntry]) {
        guard !removed.isEmpty else { return }
        let fingerprints = Array(Set(removed.compactMap(\.fingerprint)))
        NotificationCenter.default.post(
            name: Self.didRemoveHistoryNotification,
            object: self,
            userInfo: [
                "fingerprints": fingerprints,
                "ids": removed.map(\.id),
            ]
        )
    }

    /// 内存裁剪规则与 SQL 一致：先淘汰最旧的非收藏，收藏超限才动收藏里最旧的。
    /// 返回被裁掉的记录（供缓存失效通知）。
    @discardableResult
    private func trimInMemory(limit: Int? = nil) -> [HistoryEntry] {
        let limit = max(limit ?? retention(), 1)
        var removed: [HistoryEntry] = []
        while entries.count > limit {
            let index = entries.indices.dropFirst().last(where: { !entries[$0].isFavorite })
                ?? entries.indices.last!
            removed.append(entries.remove(at: index))
        }
        return removed
    }

    // MARK: - 保留条数与磁盘空间

    /// 当前生效的保留条数
    var retentionLimit: Int { retention() }

    /// 把上限调整到 limit 时预计删除的条数（只算最旧的非收藏；收藏不动）。
    /// 设置页在确认前展示这个数字，避免用户以为「只是改个设置」。
    func trimPreview(for limit: Int) -> Int {
        let excess = max(entries.count - max(limit, 1), 0)
        return min(excess, entries.filter { !$0.isFavorite }.count)
    }

    /// 应用新的保留条数：内存按同一规则裁剪，后台事务同步磁盘。返回内存中实际删除的条数
    @discardableResult
    func applyRetentionLimit(_ limit: Int) -> Int {
        let evicted = trimInMemory(limit: limit)
        let removed = evicted.count
        if removed > 0 {
            notifyChange()
            notifyRemoval(evicted)
        }
        persist("应用历史保留条数") { database in
            _ = try database.trim(to: limit)
        }
        return removed
    }

    /// 只清理非收藏记录（保留生词），返回删除条数
    @discardableResult
    func removeNonFavorites() -> Int {
        let evicted = entries.filter { !$0.isFavorite }
        entries.removeAll { !$0.isFavorite }
        let removed = evicted.count
        notifyChange()
        notifyRemoval(evicted)
        persist("清理非收藏记录") { database in
            _ = try database.deleteNonFavorites()
        }
        return removed
    }

    /// 回收磁盘空间：SQLite 删除记录后空闲页会留着复用，文件不一定变小，
    /// 只有用户显式要求释放磁盘时才执行 VACUUM（较慢，放后台），完成后刷新统计。
    func reclaimDiskSpace(completion: @escaping (Result<HistoryStorageStats, Error>) -> Void) {
        guard let database else {
            completion(.failure(HistoryDatabaseError.openFailed("历史数据库未就绪")))
            return
        }
        worker.async { [weak self] in
            do {
                try database.vacuum()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    completion(.success(self.storageStats()))
                }
            } catch {
                Task { @MainActor in completion(.failure(error)) }
            }
        }
    }

    /// 删除迁移备份与损坏备份（单独确认，不影响设置、密钥与用户导出文件）。返回释放的字节数
    @discardableResult
    func removeBackups() -> Int64 {
        var freed: Int64 = 0
        for backup in files.backups() {
            do {
                try files.removeBackup(named: backup.name)
                freed += backup.bytes
            } catch {
                lastSaveError = "删除备份 \(backup.name) 失败：\(error.localizedDescription)"
                Log.app.error("删除历史备份 \(backup.name, privacy: .public) 失败：\(error.localizedDescription)")
            }
        }
        return freed
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

    // MARK: - 通知

    /// 广播变更（历史窗口订阅后实时刷新；调用方均在主线程）
    private func notifyChange() {
        refreshReuseIndex()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}