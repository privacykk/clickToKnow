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
        let reloaded = HistoryStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries.first?.term, "helm")
        XCTAssertEqual(reloaded.entries.first?.content, "包管理器")
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
        XCTAssertEqual(HistoryStore(directory: directory).entries.count, 0)
    }
}
