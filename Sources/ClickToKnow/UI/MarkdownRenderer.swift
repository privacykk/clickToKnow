import AppKit

/// Markdown → NSAttributedString，用于弹窗 NSTextView。
///
/// 结构解析统一走 `MarkdownDocument`（与历史详情的 SwiftUI 版共用），这里只负责排版：
/// 标题按层级放大加粗、列表加项目符号、引用加竖线并转次要色、代码块等宽、分隔线画横线，
/// 行内支持加粗 / 行内代码 / 链接。表格不做排版（见 `MarkdownDocument` 的支持边界）。
enum MarkdownRenderer {
    /// 正文基准字号
    static let fontSize: CGFloat = 14

    /// 逐块转换；颜色全部用动态系统色，自动适配亮暗外观
    static func render(_ markdown: String) -> NSAttributedString {
        let document = MarkdownDocument.parse(markdown)
        let output = NSMutableAttributedString()

        for (index, block) in document.blocks.enumerated() {
            if index > 0 {
                // 列表项之间单换行，其余块之间空一行，保持可读段落感
                output.append(NSAttributedString(string: separator(between: document.blocks[index - 1], and: block)))
            }
            output.append(render(block))
        }
        return output
    }

    /// 块间距：列表与列表/标题之间紧凑，其他空行分隔
    private static func separator(between previous: MarkdownDocument.Block, and next: MarkdownDocument.Block) -> String {
        if case .bullet = previous, case .bullet = next { return "\n" }
        return "\n\n"
    }

    /// 单块排版
    private static func render(_ block: MarkdownDocument.Block) -> NSAttributedString {
        switch block {
        case .heading(let text, let level):
            return inline(text, font: headingFont(level), color: NSColor.labelColor)
        case .bullet(let text, let marker):
            let output = NSMutableAttributedString()
            output.append(NSAttributedString(string: "\(marker) ", attributes: attributes(
                font: bodyFont, color: NSColor.secondaryLabelColor
            )))
            output.append(inline(text, font: bodyFont, color: NSColor.labelColor))
            return output
        case .quote(let text):
            let output = NSMutableAttributedString()
            output.append(NSAttributedString(string: "▏", attributes: attributes(
                font: bodyFont, color: NSColor.tertiaryLabelColor
            )))
            output.append(inline(text, font: bodyFont, color: NSColor.secondaryLabelColor))
            return output
        case .code(let code):
            return NSAttributedString(string: code, attributes: attributes(font: codeFont, color: NSColor.labelColor))
        case .divider:
            return NSAttributedString(string: "─────", attributes: attributes(
                font: bodyFont, color: NSColor.tertiaryLabelColor
            ))
        case .paragraph(let text):
            return inline(text, font: bodyFont, color: NSColor.labelColor)
        }
    }

    /// 行内片段：普通 / 加粗 / 行内代码 / 链接
    private static func inline(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for segment in MarkdownDocument.inlineSegments(text) {
            var attrs = attributes(font: font, color: color)
            switch segment.style {
            case .normal:
                break
            case .bold:
                attrs[.font] = NSFont.boldSystemFont(ofSize: font.pointSize)
            case .code:
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            case .link(let url):
                attrs[.foregroundColor] = NSColor.linkColor
                if let parsed = URL(string: url) { attrs[.link] = parsed }
            }
            output.append(NSAttributedString(string: segment.text, attributes: attrs))
        }
        return output
    }

    // MARK: - 字体

    private static var bodyFont: NSFont { NSFont.systemFont(ofSize: fontSize) }
    private static var codeFont: NSFont { NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular) }

    /// 标题字号随层级递减，一级最醒目（弹窗宽度有限，不做超大标题）
    private static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return NSFont.boldSystemFont(ofSize: fontSize + 4)
        case 2: return NSFont.boldSystemFont(ofSize: fontSize + 2)
        case 3: return NSFont.boldSystemFont(ofSize: fontSize + 1)
        default: return NSFont.boldSystemFont(ofSize: fontSize)
        }
    }

    private static func attributes(font: NSFont, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }
}