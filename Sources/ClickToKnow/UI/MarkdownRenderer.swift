import AppKit

/// 极简 Markdown → NSAttributedString，支持 **加粗** 与 `- ` 列表前缀，够 LLM 输出用（KISS）。
enum MarkdownRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: 14)
        let bold = NSFont.boldSystemFont(ofSize: 14)
        let color = NSColor.labelColor
        let output = NSMutableAttributedString()

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var text = String(line)
            if text.hasPrefix("- ") {
                text = "• " + text.dropFirst(2)
            }

            // 按 ** 分段，奇数段为加粗
            let parts = text.components(separatedBy: "**")
            for (index, part) in parts.enumerated() where !part.isEmpty {
                let font = (index % 2 == 1) ? bold : base
                output.append(NSAttributedString(string: part, attributes: [
                    .font: font,
                    .foregroundColor: color
                ]))
            }
            output.append(NSAttributedString(string: "\n"))
        }
        return output
    }
}