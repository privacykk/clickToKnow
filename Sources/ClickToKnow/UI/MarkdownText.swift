import SwiftUI

/// SwiftUI 版轻量 Markdown 排版，服务于历史详情等普通 SwiftUI 视图
/// （可直接继承动态字体与亮暗外观）。
///
/// 块级解析与弹窗的 `MarkdownRenderer` 共用 `MarkdownDocument`：同一段释义在两处
/// 结构一致，不会再出现「弹窗认列表、历史详情不认」这类分叉。
/// 行内仍交给系统 `AttributedString(markdown:)` 渲染（斜体/行内代码/链接更完整），
/// 属于「怎么画」的差异，不影响读到什么。
struct MarkdownText: View {
    /// 原始 Markdown 文本（LLM 释义或系统词典纯文本）
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(MarkdownDocument.parse(markdown).blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - 块级渲染

    /// 按块类型套用不同排版；标题/代码块与上文拉开距离，避免整段糊在一起
    @ViewBuilder
    private func blockView(_ block: MarkdownDocument.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let text, let level):
            inline(text)
                .font(headingFont(level))
                .padding(.top, isFirst ? 0 : 5)
        case .bullet(let text, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(marker)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                inline(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.quaternary)
                    .frame(width: 3)
                inline(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .divider:
            Divider()
        case .paragraph(let text):
            inline(text)
                .font(.callout)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 标题字号随层级递减，一级最醒目
    private func headingFont(_ level: Int) -> Font {
        if level <= 1 { return .title3.bold() }
        if level == 2 { return .headline }
        return .subheadline.bold()
    }

    /// 内联 Markdown 交给系统渲染；解析失败时原样显示，保证任何文本都能读
    private func inline(_ raw: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(raw)
        }
        return Text(attributed)
    }
}
