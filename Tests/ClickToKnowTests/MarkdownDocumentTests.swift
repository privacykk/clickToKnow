import AppKit
import XCTest

@testable import ClickToKnow

/// 共享 Markdown 解析（评审工程项 3）：弹窗与历史详情必须读到同一份结构，
/// 行内强调要覆盖加粗 / 行内代码 / 链接，且任何输入都不能丢内容。
final class MarkdownDocumentTests: XCTestCase {
    // MARK: - 块级解析

    /// 典型 LLM 释义：标题 + 粗体标签 + 列表 + 空行
    func test_parsesTypicalInterpretation() {
        let markdown = """
        ## helm

        - **音标**：/hɛlm/
        - **领域**：Kubernetes
        **含义**：Kubernetes 的包管理器
        """
        let blocks = MarkdownDocument.parse(markdown).blocks
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0], .heading("helm", level: 2))
        XCTAssertEqual(blocks[1], .bullet("**音标**：/hɛlm/", marker: "•"))
        XCTAssertEqual(blocks[2], .bullet("**领域**：Kubernetes", marker: "•"))
        XCTAssertEqual(blocks[3], .paragraph("**含义**：Kubernetes 的包管理器"))
    }

    /// 有序列表保留序号，无序列表统一项目符号
    func test_parsesListMarkers() {
        let blocks = MarkdownDocument.parse("1. 第一\n2) 第二\n- 第三\n* 第四").blocks
        // 有序列表的 marker 自带分隔符，渲染器只补空格（"1. 第一"）
        XCTAssertEqual(blocks, [
            .bullet("第一", marker: "1."),
            .bullet("第二", marker: "2."),
            .bullet("第三", marker: "•"),
            .bullet("第四", marker: "•"),
        ])
    }

    /// 代码块合并为单块，且围栏未闭合也不丢内容
    func test_parsesCodeFenceAndUnclosedFence() {
        XCTAssertEqual(MarkdownDocument.parse("```swift\nlet a = 1\nlet b = 2\n```").blocks,
                       [.code("let a = 1\nlet b = 2")])
        XCTAssertEqual(MarkdownDocument.parse("```\n未闭合").blocks, [.code("未闭合")])
    }

    /// 引用、分隔线、空输入
    func test_parsesQuoteDividerAndEmpty() {
        XCTAssertEqual(MarkdownDocument.parse("> 出自 RFC 7540").blocks, [.quote("出自 RFC 7540")])
        XCTAssertEqual(MarkdownDocument.parse("---").blocks, [.divider])
        XCTAssertTrue(MarkdownDocument.parse("").blocks.isEmpty)
        XCTAssertTrue(MarkdownDocument.parse("   \n\n").blocks.isEmpty)
    }

    /// 表格不支持：必须按段落原样保留，不能静默丢行（这就是明确的支持边界）
    func test_tableFallsBackToParagraphWithoutLosingContent() {
        let blocks = MarkdownDocument.parse("| 列 A | 列 B |\n| --- | --- |\n| 1 | 2 |").blocks
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .paragraph("| 列 A | 列 B |"))
        XCTAssertEqual(blocks[2], .paragraph("| 1 | 2 |"))
    }

    /// `#xxx`（无空格）不是标题；`#######`（7 级）也不认
    func test_headingRequiresSpaceAndMaxSixLevels() {
        XCTAssertEqual(MarkdownDocument.parse("#hashtag").blocks, [.paragraph("#hashtag")])
        XCTAssertEqual(MarkdownDocument.parse("####### 七级").blocks, [.paragraph("####### 七级")])
    }

    // MARK: - 行内解析

    /// 粗体 / 行内代码 / 链接混排
    func test_inlineSegmentsCoverBoldCodeAndLink() {
        let segments = MarkdownDocument.inlineSegments("**粗体** 与 `code()` 和 [文档](https://example.com)")
        XCTAssertEqual(segments, [
            .init(text: "粗体", style: .bold),
            .init(text: " 与 ", style: .normal),
            .init(text: "code()", style: .code),
            .init(text: " 和 ", style: .normal),
            .init(text: "文档", style: .link(url: "https://example.com")),
        ])
    }

    /// 标记不成对时按普通文字处理，绝不吞字符
    func test_unpairedMarkersStayLiteral() {
        XCTAssertEqual(MarkdownDocument.inlineSegments("2 ** 3 = 8"), [.init(text: "2 ** 3 = 8", style: .normal)])
        XCTAssertEqual(MarkdownDocument.inlineSegments("`未闭合"), [.init(text: "`未闭合", style: .normal)])
        XCTAssertEqual(MarkdownDocument.inlineSegments("[标题]"), [.init(text: "[标题]", style: .normal)])
    }

    /// 拼接后的文字必须与原文一致（除标记本身）——保证不丢内容
    func test_inlineSegmentsPreserveAllVisibleText() {
        let source = "**音标**：/hɛlm/，`helm` 见 [文档](https://helm.sh)"
        let joined = MarkdownDocument.inlineSegments(source).map(\.text).joined()
        XCTAssertEqual(joined, "音标：/hɛlm/，helm 见 文档")
    }

    // MARK: - 弹窗渲染器

    /// 渲染器不把 Markdown 标记原样显示给用户
    func test_rendererStripsMarkers() {
        let rendered = MarkdownRenderer.render("## helm\n\n- **音标**：/hɛlm/\n- `kubectl` 命令")
        let text = rendered.string
        XCTAssertFalse(text.contains("##"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertTrue(text.contains("音标：/hɛlm/"))
        XCTAssertTrue(text.contains("• "))
    }

    /// 行内代码用等宽字体，粗体用粗体字体（弹窗侧的「怎么画」）
    func test_rendererAppliesInlineStyles() {
        let rendered = MarkdownRenderer.render("**粗**与`窄`")
        var boldTraits: NSFontTraitMask?
        var mono = false
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let substring = (rendered.string as NSString).substring(with: range)
            if substring == "粗" {
                boldTraits = NSFontManager.shared.traits(of: font)
            }
            if substring == "窄" {
                mono = font.isFixedPitch || NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
            }
        }
        XCTAssertTrue(boldTraits?.contains(.boldFontMask) ?? false, "粗体片段应为粗体字体")
        XCTAssertTrue(mono, "行内代码应为等宽字体")
    }

    /// 标题比正文更大更粗
    func test_rendererHeadingIsLargerThanBody() {
        let rendered = MarkdownRenderer.render("# 标题\n正文")
        var sizes: [CGFloat] = []
        rendered.enumerateAttribute(.font, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let font = value as? NSFont { sizes.append(font.pointSize) }
        }
        XCTAssertEqual(sizes.max(), MarkdownRenderer.fontSize + 4)
        XCTAssertEqual(sizes.min(), MarkdownRenderer.fontSize)
    }

    /// 链接保留可点属性与 url
    func test_rendererKeepsLinkAttribute() {
        let rendered = MarkdownRenderer.render("见 [文档](https://helm.sh)")
        var found: URL?
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { found = url }
        }
        XCTAssertEqual(found?.absoluteString, "https://helm.sh")
    }

    /// 空输入渲染成空串（调用方不必特判）
    func test_rendererHandlesEmptyInput() {
        XCTAssertEqual(MarkdownRenderer.render("").string, "")
        XCTAssertEqual(MarkdownRenderer.render("   ").string, "")
    }

    /// 纯文本（系统词典结果）原样渲染
    func test_rendererKeepsPlainText() {
        let rendered = MarkdownRenderer.render("helm | /hɛlm/ | 舵")
        XCTAssertTrue(rendered.string.contains("helm | /hɛlm/ | 舵"))
    }
}