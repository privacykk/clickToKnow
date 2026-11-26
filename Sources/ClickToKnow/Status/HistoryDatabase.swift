import Foundation
import SQLite3

/// SQLite 操作的失败原因。上层据此决定是「可重试」「提示用户」还是「保持旧数据不动」。
enum HistoryDatabaseError: LocalizedError, Equatable {
    /// 打开失败（权限、磁盘、文件被占用等）。调用方不得删除重建，也不得回退 JSON 写入
    case openFailed(String)
    /// 数据库来自更高版本：只读不改，避免旧版覆盖新版结构
    case futureSchema(found: Int32, supported: Int32)
    /// 语句执行失败（含约束、IO）
    case statement(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "历史数据库无法打开：\(message)"
        case .futureSchema(let found, let supported):
            return "历史数据库版本（\(found)）高于当前应用支持的版本（\(supported)），未做任何修改"
        case .statement(let message): return "历史数据库操作失败：\(message)"
        }
    }
}

/// 本机历史存储：macOS 系统 SQLite（`libsqlite3`），文件位于
/// `~/Library/Application Support/ClickToKnow/history.sqlite3`。
///
/// 只负责 SQL：建表/版本、增删改查、事务与裁剪。迁移、文件统计、通知与 UI 状态都在上层。
/// 线程安全：所有语句在内部串行队列上执行，调用方可同步调用（写入本身很快，慢的 VACUUM 由上层放后台）。
final class HistoryDatabase: @unchecked Sendable {
    /// 当前表结构版本（`PRAGMA user_version`）。结构变化时递增，并在 migrate 里补升级路径
    static let schemaVersion: Int32 = 1

    /// 旧 JSON 已导入并提交的标记（与导入同事务写入，避免重复导入）
    static let legacyImportMarker = "legacyJSONImported"

    let fileURL: URL
    private let queue: DispatchQueue
    private var handle: OpaquePointer?

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: "com.clicktoknow.history.db")
        var pointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(fileURL.path, &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "错误码 \(code)"
            sqlite3_close(pointer)
            throw HistoryDatabaseError.openFailed(message)
        }
        handle = pointer
        // 历史库只有本进程读写；仍留出余量，避免杀进程后系统刚回收连接时的瞬时占用
        sqlite3_busy_timeout(pointer, 3000)
        do {
            try configureSchema()
        } catch {
            sqlite3_close(pointer)
            handle = nil
            throw error
        }
    }

    deinit { close() }

    /// 关闭连接（重复调用安全）
    func close() {
        queue.sync {
            guard let handle else { return }
            sqlite3_close(handle)
            self.handle = nil
        }
    }

    // MARK: - 表结构与版本

    /// 校验版本并建表。更高版本直接拒绝（不写入、不重建），由上层提示用户
    private func configureSchema() throws {
        try withHandle { handle in
            let version = try scalar(handle, sql: "PRAGMA user_version")
            if version > Self.schemaVersion {
                throw HistoryDatabaseError.futureSchema(
                    found: Int32(version), supported: Self.schemaVersion
                )
            }
            guard version < Self.schemaVersion else { return }
            try transaction(handle) {
                try exec(handle, """
                CREATE TABLE IF NOT EXISTS history (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    term TEXT NOT NULL,
                    content TEXT NOT NULL,
                    source TEXT NOT NULL,
                    model TEXT,
                    created_at REAL NOT NULL,
                    favorite INTEGER NOT NULL DEFAULT 0,
                    fingerprint TEXT
                )
                """)
                // 列表排序（时间 + 序号）与「按指纹取最新一条」各一个索引
                try exec(handle, """
                CREATE INDEX IF NOT EXISTS idx_history_order
                ON history (created_at DESC, seq DESC)
                """)
                try exec(handle, """
                CREATE INDEX IF NOT EXISTS idx_history_fingerprint
                ON history (fingerprint, created_at DESC, seq DESC)
                """)
                // 自动裁剪「最旧的非收藏」需要按收藏过滤的排序索引
                try exec(handle, """
                CREATE INDEX IF NOT EXISTS idx_history_favorite_order
                ON history (favorite, created_at ASC, seq ASC)
                """)
                try exec(handle, "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
                try exec(handle, "PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
    }

    // MARK: - 查询

    /// 全量记录（新 → 旧）
    func all() throws -> [HistoryEntry] {
        try withHandle { handle in
            let statement = try prepare(handle, Self.selectColumns + " ORDER BY created_at DESC, seq DESC")
            defer { sqlite3_finalize(statement) }
            var result: [HistoryEntry] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw error(handle, code) }
                result.append(try entry(from: statement, handle: handle))
            }
            return result
        }
    }

    /// 记录数
    func count() throws -> Int {
        try withHandle { handle in Int(try scalar(handle, sql: "SELECT COUNT(*) FROM history")) }
    }

    /// 按查询指纹取最新一条（第三步的历史复用用；迁移来的记录指纹为空，不参与）
    func latest(fingerprint: String) throws -> HistoryEntry? {
        try withHandle { handle in
            let statement = try prepare(
                handle,
                Self.selectColumns + " WHERE fingerprint = ? ORDER BY created_at DESC, seq DESC LIMIT 1"
            )
            defer { sqlite3_finalize(statement) }
            try bind(handle, statement, 1, fingerprint)
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw error(handle, code) }
            return try entry(from: statement, handle: handle)
        }
    }

    // MARK: - 写入

    /// 追加一条记录并裁剪到上限（同一事务）。返回被自动淘汰的记录 id，供内存镜像同步。
    /// 淘汰规则与旧版一致：优先最旧的非收藏；收藏本身超限时才动收藏里最旧的。
    @discardableResult
    func insert(_ entry: HistoryEntry, limit: Int) throws -> [HistoryEntry.ID] {
        try withHandle { handle in
            try transaction(handle) {
                let statement = try prepare(handle, """
                INSERT INTO history (id, term, content, source, model, created_at, favorite, fingerprint)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(statement) }
                try bind(handle, statement, 1, entry.id.uuidString)
                try bind(handle, statement, 2, entry.term)
                try bind(handle, statement, 3, entry.content)
                try bind(handle, statement, 4, entry.source)
                try bindOptional(handle, statement, 5, entry.model)
                try bind(handle, statement, 6, entry.date.timeIntervalSince1970)
                try bind(handle, statement, 7, Int32(entry.isFavorite ? 1 : 0))
                try bindOptional(handle, statement, 8, entry.fingerprint)
                try step(handle, statement)

                let total = Int(try scalar(handle, sql: "SELECT COUNT(*) FROM history"))
                let excess = total - max(limit, 1)
                guard excess > 0 else { return [] }
                var removed: [HistoryEntry.ID] = []
                let evictable = try oldest(handle, limit: excess, onlyNonFavorites: true)
                removed += evictable.map(\.id)
                try deleteSequences(handle, evictable.map(\.seq))
                let remaining = excess - evictable.count
                if remaining > 0 {
                    let favorites = try oldest(handle, limit: remaining, onlyNonFavorites: false)
                    removed += favorites.map(\.id)
                    try deleteSequences(handle, favorites.map(\.seq))
                }
                return removed
            }
        }
    }

    /// 按新的保留上限裁剪（降低档位时使用）：规则与写入时一致，只动最旧的非收藏。
    /// 返回被删除的记录 id，供内存镜像同步。
    @discardableResult
    func trim(to limit: Int) throws -> [HistoryEntry.ID] {
        try withHandle { handle in
            try transaction(handle) {
                let total = Int(try scalar(handle, sql: "SELECT COUNT(*) FROM history"))
                let excess = total - max(limit, 1)
                guard excess > 0 else { return [] }
                var removed: [HistoryEntry.ID] = []
                let evictable = try oldest(handle, limit: excess, onlyNonFavorites: true)
                removed += evictable.map(\.id)
                try deleteSequences(handle, evictable.map(\.seq))
                let remaining = excess - evictable.count
                if remaining > 0 {
                    let favorites = try oldest(handle, limit: remaining, onlyNonFavorites: false)
                    removed += favorites.map(\.id)
                    try deleteSequences(handle, favorites.map(\.seq))
                }
                return removed
            }
        }
    }

    /// 只删除非收藏记录（保留生词），返回删除条数
    @discardableResult
    func deleteNonFavorites() throws -> Int {
        try withHandle { handle in
            try exec(handle, "DELETE FROM history WHERE favorite = 0")
            return Int(sqlite3_changes(handle))
        }
    }

    /// 设置收藏状态；记录不存在时返回 false
    @discardableResult
    func setFavorite(_ id: HistoryEntry.ID, favorite: Bool) throws -> Bool {
        try withHandle { handle in
            let statement = try prepare(handle, "UPDATE history SET favorite = ? WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(handle, statement, 1, Int32(favorite ? 1 : 0))
            try bind(handle, statement, 2, id.uuidString)
            try step(handle, statement)
            return sqlite3_changes(handle) > 0
        }
    }

    /// 删除单条记录；不存在时返回 false
    @discardableResult
    func delete(_ id: HistoryEntry.ID) throws -> Bool {
        try withHandle { handle in
            let statement = try prepare(handle, "DELETE FROM history WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            try bind(handle, statement, 1, id.uuidString)
            try step(handle, statement)
            return sqlite3_changes(handle) > 0
        }
    }

    /// 清空全部记录（迁移标记、结构版本都保留，避免重启后重新导回已删除数据）
    func deleteAll() throws {
        try withHandle { handle in
            try transaction(handle) {
                try exec(handle, "DELETE FROM history")
            }
        }
    }

    /// 旧 JSON 一次性导入：所有记录 + 「已导入」标记在同一事务提交。
    /// 提交前中断则整体回滚，标记未写入，下次启动会重试导入而不是双写。
    /// `beforeCommit` 仅供单测在提交前注入失败，用来验证回滚。
    func importLegacy(_ entries: [HistoryEntry], beforeCommit: (() throws -> Void)? = nil) throws {
        try withHandle { handle in
            try transaction(handle) {
                let statement = try prepare(handle, """
                INSERT OR IGNORE INTO history (id, term, content, source, model, created_at, favorite, fingerprint)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
                defer { sqlite3_finalize(statement) }
                // 旧文件是新 → 旧排列；反向写入让 seq 与时间顺序一致，同时间戳也能稳定复原
                for entry in entries.reversed() {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bind(handle, statement, 1, entry.id.uuidString)
                    try bind(handle, statement, 2, entry.term)
                    try bind(handle, statement, 3, entry.content)
                    try bind(handle, statement, 4, entry.source)
                    try bindOptional(handle, statement, 5, entry.model)
                    try bind(handle, statement, 6, entry.date.timeIntervalSince1970)
                    try bind(handle, statement, 7, Int32(entry.isFavorite ? 1 : 0))
                    try bindOptional(handle, statement, 8, entry.fingerprint)
                    try step(handle, statement)
                }
                try beforeCommit?()
                try setMeta(handle, key: Self.legacyImportMarker, value: "1")
            }
        }
    }

    /// 旧 JSON 是否已导入完成（提交过的标记）
    func hasImportedLegacyJSON() throws -> Bool {
        try withHandle { handle in
            try meta(handle, key: Self.legacyImportMarker) != nil
        }
    }

    /// 回收空闲页。SQLite 删除记录后文件不一定缩小，用户显式要求释放磁盘时才调用
    func vacuum() throws {
        try queue.sync {
            guard let handle else { throw HistoryDatabaseError.openFailed("数据库已关闭") }
            try exec(handle, "VACUUM")
        }
    }

    // MARK: - SQL 细节

    private static let selectColumns = """
    SELECT id, term, content, source, model, created_at, favorite, fingerprint FROM history
    """

    /// 取最旧的若干条（onlyNonFavorites = true 时只考虑非收藏）
    private func oldest(
        _ handle: OpaquePointer, limit: Int, onlyNonFavorites: Bool
    ) throws -> [(seq: Int64, id: HistoryEntry.ID)] {
        let filter = onlyNonFavorites ? " WHERE favorite = 0" : ""
        let statement = try prepare(
            handle,
            "SELECT seq, id FROM history\(filter) ORDER BY created_at ASC, seq ASC LIMIT ?"
        )
        defer { sqlite3_finalize(statement) }
        try bind(handle, statement, 1, Int64(limit))
        var result: [(Int64, HistoryEntry.ID)] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw error(handle, code) }
            guard let text = sqlite3_column_text(statement, 1),
                  let id = UUID(uuidString: String(cString: text)) else { continue }
            result.append((sqlite3_column_int64(statement, 0), id))
        }
        return result
    }

    private func deleteSequences(_ handle: OpaquePointer, _ sequences: [Int64]) throws {
        guard !sequences.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: sequences.count).joined(separator: ",")
        let statement = try prepare(handle, "DELETE FROM history WHERE seq IN (\(placeholders))")
        defer { sqlite3_finalize(statement) }
        for (index, seq) in sequences.enumerated() {
            try bind(handle, statement, Int32(index + 1), seq)
        }
        try step(handle, statement)
    }

    private func entry(from statement: OpaquePointer, handle: OpaquePointer) throws -> HistoryEntry {
        guard let idText = sqlite3_column_text(statement, 0),
              let id = UUID(uuidString: String(cString: idText)) else {
            throw HistoryDatabaseError.statement("记录 id 无法解析")
        }
        let model = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(statement, 4))
        let fingerprint = sqlite3_column_type(statement, 7) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(statement, 7))
        return HistoryEntry(
            term: String(cString: sqlite3_column_text(statement, 1)),
            content: String(cString: sqlite3_column_text(statement, 2)),
            source: String(cString: sqlite3_column_text(statement, 3)),
            model: model,
            date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            id: id,
            favorite: sqlite3_column_int(statement, 6) != 0,
            fingerprint: fingerprint
        )
    }

    private func meta(_ handle: OpaquePointer, key: String) throws -> String? {
        let statement = try prepare(handle, "SELECT value FROM meta WHERE key = ?")
        defer { sqlite3_finalize(statement) }
        try bind(handle, statement, 1, key)
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW else { throw error(handle, code) }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    private func setMeta(_ handle: OpaquePointer, key: String, value: String) throws {
        let statement = try prepare(
            handle, "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value"
        )
        defer { sqlite3_finalize(statement) }
        try bind(handle, statement, 1, key)
        try bind(handle, statement, 2, value)
        try step(handle, statement)
    }

    private func transaction<T>(_ handle: OpaquePointer, _ body: () throws -> T) throws -> T {
        try exec(handle, "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec(handle, "COMMIT")
            return value
        } catch {
            try? exec(handle, "ROLLBACK")
            throw error
        }
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw HistoryDatabaseError.statement(text)
        }
        sqlite3_free(message)
    }

    private func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw error(handle, SQLITE_ERROR)
        }
        return statement
    }

    private func bind(_ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32, _ text: String) throws {
        guard sqlite3_bind_text(statement, index, text, -1, Self.transient) == SQLITE_OK else {
            throw error(handle, SQLITE_ERROR)
        }
    }

    private func bind(_ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32, _ value: Int64) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw error(handle, SQLITE_ERROR)
        }
    }

    private func bind(_ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32, _ value: Int32) throws {
        guard sqlite3_bind_int(statement, index, value) == SQLITE_OK else {
            throw error(handle, SQLITE_ERROR)
        }
    }

    private func bind(_ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32, _ value: Double) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw error(handle, SQLITE_ERROR)
        }
    }

    private func bindOptional(
        _ handle: OpaquePointer, _ statement: OpaquePointer, _ index: Int32, _ text: String?
    ) throws {
        guard let text else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw error(handle, SQLITE_ERROR)
            }
            return
        }
        try bind(handle, statement, index, text)
    }

    private func step(_ handle: OpaquePointer, _ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(handle, code) }
    }

    private func scalar(_ handle: OpaquePointer, sql: String) throws -> Int64 {
        let statement = try prepare(handle, sql)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw error(handle, code) }
        return sqlite3_column_int64(statement, 0)
    }

    private func error(_ handle: OpaquePointer, _ code: Int32) -> HistoryDatabaseError {
        HistoryDatabaseError.statement("(\(code)) \(String(cString: sqlite3_errmsg(handle)))")
    }

    private func withHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try queue.sync {
            guard let handle else { throw HistoryDatabaseError.openFailed("数据库已关闭") }
            return try body(handle)
        }
    }

    /// SQLITE_TRANSIENT：让 SQLite 自己复制绑定的字符串，避免悬垂指针
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}