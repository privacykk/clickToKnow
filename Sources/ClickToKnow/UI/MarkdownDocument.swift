import Foundation

/// 共享的 Markdown 结构解析。
///
/// 原先弹窗（`MarkdownRenderer` → NSAttributedString）与历史详情（`MarkdownText` → SwiftUI）
/// 各写一套解析：一边只认 `**粗体**` 与 `- `，另一边还认标题/引用/代码块/分隔线。
/// 结果是**同一段释义在两处显示不一样**，且给弹窗补格式时必须改两份。
/// 现在解析只此一份，两个渲染器只决定「怎么画」。
///
/// 明确的支持边界（够 LLM 释义用，不做完整 CommonMark）：
/// - 支持：段落、`#`~`######` 标题、无序（`-`/`*`/`•`）与有序（`1.`/`1)`）列表、
///   `> ` 引用、``` 代码围栏、`---`/`***`/`___` 分隔线；
/// - 行内：`**粗体**`、`` `行内代码` ``、`[文字](链接)`；不支持行内嵌套（粗体里再嵌代码）；
/// - **不支持表格**：`| a | b |` 这类行按普通段落原样显示（不做表格排版，也不静默丢内容）。
struct MarkdownDocument: Equatable {
    /// 块级元素
    enum Block: Equatable {
        case heading(String, level: Int)
        case bullet(String, marker: String)
        case quote(String)
        case code(String)
        case divider
        case paragraph(String)
    }

    /// 行内片段及其强调方式
    struct InlineSegment: Equatable {
        enum Style: Equatable {
            case normal
            case bold
            /// 行内代码（等宽显示）
            case code
            /// 链接：显示 label，保留 url 供渲染器决定是否可点
            case link(url: String)
        }

        let text: String
        let style: Style
    }

    let blocks: [Block]

    /// 空文本 / 纯空白视为零块（渲染器无需特判）
    static func parse(_ markdown: String) -> MarkdownDocument {
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
        return MarkdownDocument(blocks: blocks)
    }

    /// 行内切分：`**粗体**`、`` `代码` ``、`[文字](链接)`。
    /// 标记不成对时按普通文字处理，保证任何输入都能读出内容。
    static func inlineSegments(_ text: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var plain = ""
        var index = text.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            segments.append(InlineSegment(text: plain, style: .normal))
            plain = ""
        }

        while index < text.endIndex {
            let remainder = text[index...]

            // **粗体**
            if remainder.hasPrefix("**") {
                let contentStart = text.index(index, offsetBy: 2)
                if let close = text.range(of: "**", range: contentStart..<text.endIndex) {
                    flushPlain()
                    let content = String(text[contentStart..<close.lowerBound])
                    if !content.isEmpty { segments.append(InlineSegment(text: content, style: .bold)) }
                    index = close.upperBound
                    continue
                }
            }
            // `行内代码`
            if remainder.hasPrefix("`") {
                let contentStart = text.index(after: index)
                if let close = text[contentStart..<text.endIndex].firstIndex(of: "`") {
                    flushPlain()
                    let content = String(text[contentStart..<close])
                    if !content.isEmpty { segments.append(InlineSegment(text: content, style: .code)) }
                    index = text.index(after: close)
                    continue
                }
            }
            // [文字](链接)
            if remainder.hasPrefix("["),
               let closeBracket = text[index...].firstIndex(of: "]") {
                let afterBracket = text.index(after: closeBracket)
                if afterBracket < text.endIndex, text[afterBracket] == "(",
                   let closeParen = text[afterBracket...].firstIndex(of: ")") {
                    flushPlain()
                    let labelStart = text.index(after: index)
                    let label = String(text[labelStart..<closeBracket])
                    let urlStart = text.index(after: afterBracket)
                    let url = String(text[urlStart..<closeParen])
                    if !label.isEmpty { segments.append(InlineSegment(text: label, style: .link(url: url))) }
                    index = text.index(after: closeParen)
                    continue
                }
            }

            plain.append(text[index])
            index = text.index(after: index)
        }
        flushPlain()
        return segments
    }

    // MARK: - 块级识别

    /// `#` / `##` / `###` … 标题（最多 6 级）
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