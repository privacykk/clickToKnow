import SQLite3
import XCTest

@testable import ClickToKnow

/// 旧 JSON → SQLite 的首次升级：导入一次、保留顺序与收藏、失败保留原件、
/// 提交后归档、清空后不导回、更高版本库不动。
@MainActor
final class HistoryMigrationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickToKnowMigration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    // MARK: - 辅助

    private var legacyURL: URL { directory.appendingPathComponent(HistoryFiles.legacyJSONName) }
    private var migratedURL: URL { directory.appendingPathComponent(HistoryFiles.migratedJSONName) }

    private func makeStore() -> HistoryStore {
        let store = HistoryStore(directory: directory, autostart: false)
        store.prepareSynchronously()
        return store
    }

    private func writeLegacyJSON(_ entries: [HistoryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: legacyURL)
    }

    private func makeEntry(
        _ term: String, at seconds: TimeInterval, favorite: Bool = false, id: UUID = UUID()
    ) -> HistoryEntry {
        HistoryEntry(
            term: term, content: "\(term) 的释义", source: "llm", model: "deepseek-chat",
            date: Date(timeIntervalSince1970: seconds), id: id, favorite: favorite
        )
    }

    private func makeDatabase() throws -> HistoryDatabase {
        try HistoryDatabase(fileURL: directory.appendingPathComponent(HistoryFiles.databaseName))
    }

    // MARK: - 首次启动

    /// 没有旧文件：直接初始化空库并标记完成，不产生任何警告
    func test_emptyDirectoryStartsReady() {
        let store = makeStore()
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.loadWarning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

        // 再次启动仍是空库，不会被误判成「待迁移」
        let reopened = makeStore()
        XCTAssertEqual(reopened.state, .ready)
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    /// 已有 JSON：记录、顺序、收藏、时间、id 全部保留，提交后旧文件归档
    func test_legacyJSONImportedPreservingOrderFavoriteAndDate() throws {
        let first = makeEntry("helm", at: 300, favorite: true)
        let second = makeEntry("ingress", at: 200)
        let third = makeEntry("pod", at: 100)
        try writeLegacyJSON([first, second, third])

        let store = makeStore()

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.entries.map(\.term), ["helm", "ingress", "pod"], "新 → 旧顺序必须保持")
        XCTAssertEqual(store.entries.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(store.entries.map(\.date), [first.date, second.date, third.date])
        XCTAssertEqual(store.entries.first?.favorite, true)
        XCTAssertEqual(store.entries.first?.fingerprint, nil, "迁移记录没有指纹，只能浏览")
        XCTAssertEqual(store.loadWarning, "已从旧版历史导入 3 条记录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedURL.path))
    }

    /// 同一时间戳的多条记录：靠序号保持原有顺序
    func test_sameTimestampKeepsOriginalOrder() throws {
        let same = Date(timeIntervalSince1970: 500)
        let entries = (0..<5).map { index in
            HistoryEntry(term: "term-\(index)", content: "c", source: "llm", model: nil, date: same)
        }
        try writeLegacyJSON(entries)

        let store = makeStore()

        XCTAssertEqual(store.entries.map(\.term), entries.map(\.term))
        XCTAssertEqual(makeStore().entries.map(\.term), entries.map(\.term), "重启后顺序仍稳定")
    }

    /// 重复 uuid：保留数组里较新的一条，并给出提示
    func test_duplicateUUIDKeepsNewest() throws {
        let id = UUID()
        try writeLegacyJSON([
            makeEntry("newer", at: 200, id: id),
            makeEntry("older", at: 100, id: id),
        ])

        let store = makeStore()

        XCTAssertEqual(store.entries.map(\.term), ["newer"])
        let warning = try XCTUnwrap(store.loadWarning)
        XCTAssertTrue(warning.contains("重复记录"), "实际：\(warning)")
    }

    /// 旧版文件没有 favorite / fingerprint 字段也能解码（向后兼容）
    func test_legacyJSONWithoutNewFieldsDecodes() throws {
        let raw = """
        [{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","term":"helm","content":"x",
          "source":"llm","model":"m","date":"2026-01-02T03:04:05Z"}]
        """
        try Data(raw.utf8).write(to: legacyURL)

        let store = makeStore()

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.entries.map(\.term), ["helm"])
        XCTAssertEqual(store.entries.first?.favorite, false, "旧文件没有收藏字段时按未收藏处理")
    }

    /// 0 字节文件视为「还没有历史」，不算损坏
    func test_emptyLegacyFileIsNotCorruption() throws {
        try Data().write(to: legacyURL)
        let store = makeStore()
        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedURL.path), "空文件也要归档，避免反复判待迁移")
    }

    // MARK: - 重复启动与清空

    /// 重复启动不重复导入
    func test_repeatedStartupDoesNotDuplicate() throws {
        try writeLegacyJSON([makeEntry("helm", at: 100)])
        let first = makeStore()
        XCTAssertEqual(first.entries.count, 1)

        let second = makeStore()
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertEqual(second.loadWarning, nil, "已归档后不再提示导入")
    }

    /// 清空历史后重启：迁移标记保留，不会把已删除的数据导回来
    func test_clearThenRestartDoesNotReimport() throws {
        try writeLegacyJSON([makeEntry("helm", at: 100), makeEntry("pod", at: 200)])
        let store = makeStore()
        XCTAssertEqual(store.entries.count, 2)

        store.removeAll()
        store.flush()

        let reopened = makeStore()
        XCTAssertTrue(reopened.entries.isEmpty)
        XCTAssertEqual(reopened.storageStats().recordCount, 0)
    }

    // MARK: - 故障路径

    /// 旧文件无法解析：保留原件、暂停历史功能，等用户决定
    func test_corruptLegacyJSONIsKeptAndBlocks() throws {
        let corrupt = "{ 这不是合法 JSON"
        try Data(corrupt.utf8).write(to: legacyURL)

        let store = makeStore()

        guard case .blocked(.corruptLegacyJSON(let message)) = store.state else {
            return XCTFail("应为「旧文件损坏」状态，实际 \(store.state)")
        }
        XCTAssertTrue(message.contains("无法解析"), "实际：\(message)")
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try String(contentsOf: legacyURL, encoding: .utf8), corrupt, "原件不得被改动")
        XCTAssertTrue(store.storageStats().legacyJSONPresent)
    }

    /// 用户显式选择从空历史开始：原文件备份为损坏副本，随后可以正常使用
    func test_startEmptyAfterCorruptKeepsBackup() throws {
        let corrupt = "{ 坏文件"
        try Data(corrupt.utf8).write(to: legacyURL)
        let store = makeStore()

        store.startEmptyAfterCorruptLegacy()
        store.flush()

        XCTAssertEqual(store.state, .ready)
        XCTAssertTrue(store.entries.isEmpty)
        let backups = store.files.backups().filter { $0.kind == .corrupt }
        XCTAssertEqual(backups.count, 1, "原文件必须留档")
        let backupURL = directory.appendingPathComponent(backups[0].name)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

        // 之后重启不再提示、不再导入
        let reopened = makeStore()
        XCTAssertEqual(reopened.state, .ready)
        XCTAssertTrue(reopened.entries.isEmpty)
    }

    /// 提交前中断：整体回滚，标记未写入，旧文件原样保留（下次启动重试而不是双写）
    func test_importRollsBackWhenTransactionAborts() throws {
        let database = try makeDatabase()
        defer { database.close() }
        let entries = [makeEntry("helm", at: 100), makeEntry("pod", at: 200)]

        XCTAssertThrowsError(try database.importLegacy(entries, beforeCommit: {
            throw HistoryDatabaseError.statement("模拟磁盘写入中断")
        }))

        XCTAssertEqual(try database.count(), 0, "回滚后不得留下半份数据")
        XCTAssertFalse(try database.hasImportedLegacyJSON(), "未提交就不得写入迁移标记")

        // 重试可正常导入
        try database.importLegacy(entries)
        XCTAssertEqual(try database.count(), 2)
        XCTAssertTrue(try database.hasImportedLegacyJSON())
    }

    /// 提交成功但归档失败：数据可用、标记已写；重启只补归档，不重复导入
    func test_archiveFailureDoesNotReimport() throws {
        let entries = [makeEntry("helm", at: 100), makeEntry("pod", at: 200)]
        try writeLegacyJSON(entries)
        let database = try makeDatabase()
        let files = HistoryFiles(directory: directory)
        let failing = HistoryMigration(files: files, moveItem: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })

        let output = try failing.prepare(database: database)
        XCTAssertEqual(output.entries.count, 2)
        let warning = try XCTUnwrap(output.warning)
        XCTAssertTrue(warning.contains("归档失败"), "实际：\(warning)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path), "归档失败时旧文件仍在")
        XCTAssertFalse(FileManager.default.fileExists(atPath: migratedURL.path))
        database.close()

        // 下一次启动：补归档，记录数不变
        let store = makeStore()
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migratedURL.path))
    }

    /// 更高版本的数据库：拒绝写入也不改动文件
    func test_futureSchemaIsRejected() throws {
        let databaseURL = directory.appendingPathComponent(HistoryFiles.databaseName)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version = 99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let store = makeStore()

        guard case .blocked(.unreadable(let message)) = store.state else {
            return XCTFail("应为不可用状态，实际 \(store.state)")
        }
        XCTAssertTrue(message.contains("99"), "实际：\(message)")

        // 版本号未被改回，文件也没有被重建
        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &check), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(check, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 99)
        sqlite3_finalize(statement)
        sqlite3_close(check)
    }
}