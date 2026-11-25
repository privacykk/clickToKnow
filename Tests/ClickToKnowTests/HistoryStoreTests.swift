import XCTest

@testable import ClickToKnow

/// 历史记录：新→旧排序、容量淘汰、CSV/Anki 导出转义、磁盘持久化 round-trip。
/// 每个用例用独立临时目录，不触碰真实的 Application Support 数据。
@MainActor
final class HistoryStoreTests: XCTestCase {
    private var directory: URL!
    private var store: HistoryStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickToKnowTests-\(UUID().uuidString)", isDirectory: true)
        store = HistoryStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        store = nil
        directory = nil
        super.tearDown()
    }

    /// 构造测试用释义
    private func makeInterpretation(_ term: String, content: String = "释义") -> Interpretation {
        Interpretation(term: term, content: content, source: .llm)
    }

    func test_add_insertsNewestFirst() {
        store.add(makeInterpretation("helm"), model: "deepseek-chat")
        store.add(makeInterpretation("ingress"), model: "deepseek-chat")
        XCTAssertEqual(store.entries.map(\.term), ["ingress", "helm"])
        XCTAssertEqual(store.entries[0].source, "llm")
        XCTAssertEqual(store.entries[0].model, "deepseek-chat")
    }

    func test_capacityEvictsOldest() {
        for index in 0..<510 {
            store.add(makeInterpretation("term-\(index)"), model: nil)
        }
        XCTAssertEqual(store.entries.count, 500)
        XCTAssertEqual(store.entries.first?.term, "term-509")
        XCTAssertEqual(store.entries.last?.term, "term-10")
    }

    func test_persistenceRoundTrip() {
        store.add(makeInterpretation("helm", content: "包管理器"), model: "deepseek-chat")
        store.flush()
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.term, "helm")
        XCTAssertEqual(reloaded.entries.first?.content, "包管理器")
    }

    func test_favoriteSurvivesEvictionAndReload() {
        let id = store.add(makeInterpretation("helm"), model: nil)
        XCTAssertEqual(store.toggleFavorite(id: id), true)
        for index in 0..<500 {
            store.add(makeInterpretation("word-\(index)"), model: nil)
        }
        store.flush()
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 500)
        XCTAssertEqual(reloaded.entries.last?.id, id)
        XCTAssertTrue(reloaded.entries.last?.isFavorite == true)
        XCTAssertEqual(reloaded.toggleFavorite(id: id), false)
        reloaded.flush()
    }

    /// CSV：含逗号/引号/换行的字段必须按 RFC 4180 加引号转义
    func test_exportCSV_escapesFields() {
        store.add(makeInterpretation("a,b", content: "含\"引号\"和\n换行"), model: nil)
        let csv = store.exportCSV()
        XCTAssertTrue(csv.hasPrefix("term,source,model,date,content\n"))
        XCTAssertTrue(csv.contains("\"a,b\""), "实际：\(csv)")
        XCTAssertTrue(csv.contains("\"含\"\"引号\"\"和\n换行\""), "实际：\(csv)")
    }

    /// Anki TSV：制表符转空格、内容换行转 <br>
    func test_exportAnkiTSV_convertsSeparators() {
        store.add(makeInterpretation("hel\tm", content: "第一行\n第二行"), model: nil)
        let tsv = store.exportAnkiTSV()
        XCTAssertTrue(tsv.contains("hel m\t第一行<br>第二行"), "实际：\(tsv)")
    }

    func test_removeAll() {
        store.add(makeInterpretation("helm"), model: nil)
        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
        store.flush()
        XCTAssertEqual(HistoryStore(directory: directory).entries.count, 0)
    }

    /// 单条删除只移除目标记录，其余顺序与磁盘内容保持一致
    func test_removeById() {
        store.add(makeInterpretation("helm"), model: nil)
        store.add(makeInterpretation("ingress"), model: nil)
        let target = store.entries[1]
        store.remove(id: target.id)
        XCTAssertEqual(store.entries.map(\.term), ["ingress"])
        store.flush()
        XCTAssertEqual(HistoryStore(directory: directory).entries.map(\.term), ["ingress"])
    }

    /// 删除不存在的 id 不应改动数据，也不应重复落盘
    func test_removeUnknownIdIsNoop() {
        store.add(makeInterpretation("helm"), model: nil)
        store.remove(id: UUID())
        XCTAssertEqual(store.entries.map(\.term), ["helm"])
    }

    /// 导出子集：历史窗口按当前筛选导出，选中之外的数据不应混入
    func test_exportSubset_onlyGivenEntries() {
        store.add(makeInterpretation("helm"), model: nil)
        store.add(makeInterpretation("ingress"), model: nil)
        let filtered = store.entries.filter { $0.term == "helm" }

        let csv = store.exportCSV(filtered)
        XCTAssertTrue(csv.contains("helm"))
        XCTAssertFalse(csv.contains("ingress"))

        let tsv = store.exportAnkiTSV(filtered)
        XCTAssertEqual(tsv, "helm\t释义\n")
    }

    // MARK: - 后台写入与损坏恢复

    /// 写盘不阻塞调用方：add 返回即可读内存，磁盘内容在 flush 后才保证是最新的
    func test_addDoesNotWaitForDisk() {
        store.add(makeInterpretation("helm"), model: nil)
        XCTAssertEqual(store.entries.map(\.term), ["helm"], "内存立即可见")
        store.flush()
        XCTAssertEqual(HistoryStore(directory: directory).entries.map(\.term), ["helm"])
    }

    /// 连续写入合并：中间态不必逐次落盘，最终状态必须完整
    func test_rapidWritesCoalesceToLatestState() {
        for index in 0..<50 {
            store.add(makeInterpretation("term-\(index)"), model: nil)
        }
        store.flush()
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 50)
        XCTAssertEqual(reloaded.entries.first?.term, "term-49")
        XCTAssertEqual(reloaded.entries.last?.term, "term-0")
    }

    /// 损坏文件：备份原文件 + 给出可见警告，而不是静默清空后被下一次写入覆盖
    func test_corruptedFileIsBackedUpWithVisibleWarning() throws {
        let fileURL = directory.appendingPathComponent("history.json")
        try Data("{ 这不是合法 JSON".utf8).write(to: fileURL)

        let recovered = HistoryStore(directory: directory)

        XCTAssertTrue(recovered.entries.isEmpty)
        let warning = try XCTUnwrap(recovered.loadWarning, "损坏必须给出可见警告")
        XCTAssertTrue(warning.contains("备份"))

        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("history.corrupt-") }
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(backups.count, 1, "原文件必须留档，实际目录内容：\(directoryContents)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "损坏文件应被移走，避免下次写入前误判")

        // 备份内容保持原样，仍可人工抢救
        let backupData = try Data(contentsOf: directory.appendingPathComponent(backups[0]))
        XCTAssertEqual(String(decoding: backupData, as: UTF8.self), "{ 这不是合法 JSON")
    }

    /// 正常文件不应产生警告
    func test_validFileHasNoWarning() {
        store.add(makeInterpretation("helm"), model: nil)
        store.flush()
        XCTAssertNil(HistoryStore(directory: directory).loadWarning)
    }

    /// 空文件（0 字节）视为「还没有历史」，不算损坏
    func test_emptyFileIsNotCorruption() throws {
        try Data().write(to: directory.appendingPathComponent("history.json"))
        let reloaded = HistoryStore(directory: directory)
        XCTAssertTrue(reloaded.entries.isEmpty)
        XCTAssertNil(reloaded.loadWarning)
    }
}
