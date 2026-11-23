import XCTest

@testable import ClickToKnow

/// 历史记录筛选：来源过滤、关键词 AND 语义、大小写不敏感、筛选态判定。
/// 纯值类型可直接构造，不需要真实的 HistoryStore。
final class HistoryFilterTests: XCTestCase {
    /// 构造测试条目（模型名固定 nil，不影响筛选）
    private func entry(
        _ term: String,
        content: String = "释义",
        source: Interpretation.Source = .llm
    ) -> HistoryEntry {
        HistoryEntry(term: term, content: content, source: source.rawValue, model: nil)
    }

    /// 固定的三条样本：两条大模型、一条系统词典
    private var entries: [HistoryEntry] {
        [
            entry("helm", content: "**领域**：Kubernetes 包管理器"),
            entry("舵", content: "船舵", source: .systemDictionary),
            entry("Ingress", content: "入口资源"),
        ]
    }

    func test_emptyFilterReturnsAll() {
        let filter = HistoryFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.apply(to: entries).map(\.term), ["helm", "舵", "Ingress"])
    }

    func test_sourceFilter() {
        var filter = HistoryFilter()
        filter.source = .systemDictionary
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.apply(to: entries).map(\.term), ["舵"])

        filter.source = .llm
        XCTAssertEqual(filter.apply(to: entries).map(\.term), ["helm", "Ingress"])
    }

    func test_keywordIsCaseInsensitive() {
        let filter = HistoryFilter(query: "INGRESS")
        XCTAssertEqual(filter.apply(to: entries).map(\.term), ["Ingress"])
    }

    func test_keywordMatchesContent() {
        let filter = HistoryFilter(query: "kubernetes")
        XCTAssertEqual(filter.apply(to: entries).map(\.term), ["helm"])
    }

    /// 多个关键词是 AND 语义：必须同时命中同一条记录
    func test_multipleKeywordsRequireAll() {
        XCTAssertEqual(HistoryFilter(query: "helm kubernetes").apply(to: entries).map(\.term), ["helm"])
        XCTAssertTrue(HistoryFilter(query: "helm 船舵").apply(to: entries).isEmpty)
    }

    /// 纯空白关键词不算筛选，避免输入空格就清空列表
    func test_whitespaceOnlyQueryDoesNotFilter() {
        let filter = HistoryFilter(query: "   ")
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.apply(to: entries).count, 3)
    }

    /// 来源与关键词同时生效
    func test_sourceAndKeywordCombine() {
        let filter = HistoryFilter(query: "舵", source: .llm)
        XCTAssertTrue(filter.apply(to: entries).isEmpty)
    }
}
