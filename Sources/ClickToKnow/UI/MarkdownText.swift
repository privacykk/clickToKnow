import SwiftUI

/// SwiftUI 版轻量 Markdown 排版：块级支持标题 / 有序无序列表 / 引用 / 分隔线 / 代码块，
/// 行内交给系统解析（粗体、斜体、行内代码、链接）。
/// 与弹窗使用的 NSAttributedString 版（MarkdownRenderer）分工：
/// 这里服务于历史详情等普通 SwiftUI 视图，可直接继承动态字体与亮暗外观。
struct MarkdownText: View {
    /// 原始 Markdown 文本（LLM 释义或系统词典纯文本）
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(Self.parse(markdown).enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    // MARK: - 块级渲染

    /// 按块类型套用不同排版；标题/代码块与上文拉开距离，避免整段糊在一起
    @ViewBuilder
    private func blockView(_ block: Block, isFirst: Bool) -> some View {
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

    // MARK: - 解析

    /// 可渲染的块（代码块内容已合并为单块）
    private enum Block {
        case heading(String, level: Int)
        case bullet(String, marker: String)
        case quote(String)
        case code(String)
        case divider
        case paragraph(String)
    }

    /// 逐行解析常见 Markdown 结构；空行只用于分段，不单独生成视图
    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var codeLines: [String] = []
        var inCodeFence = false

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // 代码围栏：进入/退出时把累积内容合并成一个代码块
            if line.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                }
                inCodeFence.toggle()
                continue
            }
            if inCodeFence {
                codeLines.append(rawLine)
                continue
            }

            guard !line.isEmpty else { continue }

            if line == "---" || line == "***" || line == "___" {
                blocks.append(.divider)
                continue
            }
            if let heading = heading(from: line) {
                blocks.append(heading)
                continue
            }
            if let item = bullet(from: line) {
                blocks.append(item)
                continue
            }
            if line.hasPrefix("> ") {
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }
            blocks.append(.paragraph(line))
        }

        // 围栏未闭合时也保留已读内容，避免静默丢字
        if inCodeFence, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        return blocks
    }

    /// `#` / `##` / `###` 标题（最多 6 级）
    private static func heading(from line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(text, level: hashes.count)
    }

    /// 无序列表（- / * / •）与有序列表（1. / 1)）
    private static func bullet(from line: String) -> Block? {
        for prefix in ["- ", "* ", "• "] where line.hasPrefix(prefix) {
            let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : .bullet(text, marker: "•")
        }

        // 有序列表：数字前缀 + 点/右括号 + 空格
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .bullet(text, marker: "\(digits).")
    }
}
