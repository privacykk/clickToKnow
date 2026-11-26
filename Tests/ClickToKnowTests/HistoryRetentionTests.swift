import XCTest

@testable import ClickToKnow

/// 保留条数、只清非收藏、备份清理与磁盘回收：都是用户可见的「删了什么」承诺，
/// 断言重点是「收藏不被自动删除」「只动历史相关文件」「失败不谎报已释放」。
@MainActor
final class HistoryRetentionTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickToKnowRetention-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private func makeStore(retention: Int = HistoryRetention.defaultLimit) -> HistoryStore {
        let store = HistoryStore(directory: directory, retention: { retention }, autostart: false)
        store.prepareSynchronously()
        return store
    }

    private func add(_ store: HistoryStore, count: Int, prefix: String = "term") {
        for index in 0..<count {
            store.add(Interpretation(term: "\(prefix)-\(index)", content: "释义", source: .llm), model: nil)
        }
    }

    /// 预估只统计超出上限的未收藏记录；收藏超限时不做任何删除
    func test_trimPreviewCountsOnlyNonFavorites() {
        let store = makeStore()
        add(store, count: 10, prefix: "a")
        for entry in store.entries.prefix(2) {
            store.toggleFavorite(id: entry.id)
        }
        XCTAssertEqual(store.trimPreview(for: 5), 5, "10 条里有 2 条收藏，删 5 条非收藏足够降到 5")

        let favoritesOnly = HistoryStore(
            directory: directory.appendingPathComponent("favorites"), autostart: false
        )
        favoritesOnly.prepareSynchronously()
        add(favoritesOnly, count: 4, prefix: "fav")
        for entry in favoritesOnly.entries {
            favoritesOnly.toggleFavorite(id: entry.id)
        }
        XCTAssertEqual(favoritesOnly.trimPreview(for: 1), 0, "全是收藏时不得自动删除")
    }

    /// 降低上限：只淘汰最旧的非收藏，收藏保留，磁盘与内存一致
    func test_applyRetentionLimitKeepsFavorites() {
        let store = makeStore()
        add(store, count: 10, prefix: "a")
        let oldest = store.entries.last!
        store.toggleFavorite(id: oldest.id)
        store.flush()

        let removed = store.applyRetentionLimit(5)
        store.flush()

        XCTAssertEqual(removed, 5)
        XCTAssertEqual(store.entries.count, 5)
        XCTAssertTrue(store.entries.contains { $0.id == oldest.id }, "收藏不得被自动清理")

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.entries.count, 5)
        XCTAssertTrue(reloaded.entries.contains { $0.id == oldest.id })
    }

    /// 只清理非收藏：收藏原样保留
    func test_removeNonFavoritesKeepsFavorites() {
        let store = makeStore()
        add(store, count: 6)
        let favorite = store.entries[3]
        store.toggleFavorite(id: favorite.id)
        store.flush()

        let removed = store.removeNonFavorites()
        store.flush()

        XCTAssertEqual(removed, 5)
        XCTAssertEqual(store.entries.map(\.id), [favorite.id])
        XCTAssertEqual(makeStore().entries.map(\.id), [favorite.id])
    }

    func test_retentionClampedToSupportedOptions() {
        XCTAssertEqual(HistoryRetention.clamped(200), HistoryRetention.defaultLimit)
        XCTAssertEqual(HistoryRetention.clamped(-1), HistoryRetention.defaultLimit)
        XCTAssertEqual(HistoryRetention.clamped(1_000), 1_000)
    }

    /// 备份清理只删迁移备份与损坏备份，不碰数据库、设置或用户导出文件
    func test_removeBackupsOnlyDeletesHistoryBackups() throws {
        let store = makeStore()
        store.add(Interpretation(term: "helm", content: "x", source: .llm), model: nil)
        store.flush()

        let migrated = directory.appendingPathComponent(HistoryFiles.migratedJSONName)
        let corrupt = directory.appendingPathComponent("\(HistoryFiles.corruptPrefix)2026-01-01.json")
        let userExport = directory.appendingPathComponent("我的导出.csv")
        try Data("legacy".utf8).write(to: migrated)
        try Data("broken".utf8).write(to: corrupt)
        try Data("term,content".utf8).write(to: userExport)

        XCTAssertEqual(store.files.backups().count, 2, "只把历史备份计入统计")
        XCTAssertEqual(store.files.backupBytes(), 12)

        let freed = store.removeBackups()

        XCTAssertEqual(freed, 12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userExport.path), "用户导出文件不得被删")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.files.databaseURL.path), "数据库不得被删")
        XCTAssertEqual(store.storageStats().backupBytes, 0)
    }

    /// 回收磁盘空间：完成回调带最新统计，记录数不变；空库也不会报错
    func test_reclaimDiskSpaceCompletesWithFreshStats() {
        let store = makeStore()
        add(store, count: 20)
        store.removeAll()
        store.flush()

        let expectation = expectation(description: "vacuum")
        store.reclaimDiskSpace { result in
            switch result {
            case .success(let stats):
                XCTAssertEqual(stats.recordCount, 0)
                XCTAssertGreaterThan(stats.databaseBytes, 0, "数据库文件仍在（只是空闲页被回收）")
            case .failure(let error):
                XCTFail("回收失败：\(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
    }
}