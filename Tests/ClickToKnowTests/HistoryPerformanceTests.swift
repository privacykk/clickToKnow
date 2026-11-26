import XCTest

@testable import ClickToKnow

/// 历史存储在 500 / 1,000 / 5,000 条规模下的基准（对应迁移方案第 5 节「性能验证」）。
///
/// 默认跳过：这些用例故意跑满 5,000 条真实长度的释义，单次耗时秒级，不适合每次 `swift test`。
/// 发布前用 Release 构建单独跑：
/// ```
/// CLICKTOKNOW_RUN_HISTORY_BENCHMARK=1 swift test -c release --filter HistoryPerformanceTests
/// ```
@MainActor
final class HistoryPerformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["CLICKTOKNOW_RUN_HISTORY_BENCHMARK"] == "1" else {
            throw XCTSkip("历史基准默认跳过；设置 CLICKTOKNOW_RUN_HISTORY_BENCHMARK=1 后运行")
        }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickToKnowBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // 被 XCTSkip 跳过时 root 还是 nil，不能强解包
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    /// 贴近真实长度的释义（Markdown，约 1KB）
    private func sampleContent(_ index: Int) -> String {
        """
        ## 词条 \(index)

        **技术语境**：这是第 \(index) 条示例释义，长度接近真实使用中的技术词条解释。
        在容器编排里，它通常指代一类负责网络入口的对象；在普通阅读语境下则更接近它的日常含义。

        - 常见搭配：`kubectl get ingress`、Ingress Controller
        - 易混淆点：与 Service 的区别在于它工作在七层
        - 参考：Kubernetes 官方文档「Ingress」章节

        若上下文出现「航海」「舵」等线索，应优先给出日常含义，并说明两种语境下的差异。
        """
    }

    private func makeEntries(_ count: Int) -> [HistoryEntry] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<count).map { index in
            HistoryEntry(
                term: "term-\(index)", content: sampleContent(index), source: "llm",
                model: "deepseek-chat", date: base.addingTimeInterval(Double(index)),
                favorite: index % 50 == 0
            )
        }
    }

    private func writeLegacyJSON(_ count: Int) throws -> URL {
        let directory = root.appendingPathComponent("legacy-\(count)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(makeEntries(count))
        try data.write(to: directory.appendingPathComponent(HistoryFiles.legacyJSONName))
        return directory
    }

    private func measureOnce(_ name: String, _ body: () throws -> Void) rethrows {
        let start = Date()
        try body()
        print("[bench] \(name): \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000))ms")
    }

    /// 一次性打印三个档位的迁移、冷启动、写入、搜索与裁剪耗时
    func test_benchmarkMediumAndLargeHistories() throws {
        for count in [500, 1_000, 5_000] {
            let directory = try writeLegacyJSON(count)
            let files = HistoryFiles(directory: directory)
            let database = try HistoryDatabase(fileURL: files.databaseURL)
            let migration = HistoryMigration(files: files)

            var entries: [HistoryEntry] = []
            try measureOnce("迁移 \(count) 条") {
                entries = try migration.prepare(database: database).entries
            }
            XCTAssertEqual(entries.count, count)

            try measureOnce("冷启动读取 \(count) 条") {
                _ = try database.all()
            }
            try measureOnce("单次写入（满额）\(count) 条") {
                let entry = HistoryEntry(term: "new-term", content: sampleContent(1), source: "llm", model: "m")
                _ = try database.insert(entry, limit: count)
            }
            let filter = HistoryFilter(query: "ingress", source: .all)
            try measureOnce("搜索 \(count) 条") {
                let result = filter.apply(to: entries)
                XCTAssertFalse(result.isEmpty)
            }
            try measureOnce("裁剪到 100 条") {
                _ = try database.trim(to: 100)
            }
            let bytes = files.databaseBytes()
            print("[bench] \(count) 条数据库占用：\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            database.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}