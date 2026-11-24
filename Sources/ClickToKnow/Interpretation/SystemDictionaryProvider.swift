import CoreServices
import Foundation

/// 无 LLM 配置时的兜底：查 macOS 系统本地词典/百科。
/// 本地词典按词条精确查询，选区上下文用不上（签名保持一致即可）。
final class SystemDictionaryProvider: InterpretationProvider {
    func interpret(_ text: String, context: String?) async throws -> Interpretation {
        try Task.checkCancellation()
        // 词典查询可能 >1s（初始化索引/返回 HTML），放后台线程执行。
        // 注意 Task.detached 不继承调用方取消、其 .value 也不会抛 CancellationError，
        // 取回结果后必须补一次取消检查，否则「关窗后旧的词典查询仍会重新弹出释义」。
        let definition: String? = await Task.detached(priority: .userInitiated) {
            let cfText = text as CFString
            let range = CFRange(location: 0, length: CFStringGetLength(cfText))
            return DCSCopyTextDefinition(nil, cfText, range)?.takeRetainedValue() as String?
        }.value
        try Task.checkCancellation()
        guard let definition, !definition.isEmpty else {
            throw InterpretationError.notFound
        }
        return Interpretation(
            term: text,
            content: Self.beautify(definition),
            source: .systemDictionary
        )
    }

    /// 系统词典返回的是挤成一行的紧凑文本（`词 | 音标 | 释义①… ▸ 例句`），
    /// 按分隔符换行以提升可读性。
    private static func beautify(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: " | ", with: "\n| ")
        text = text.replacingOccurrences(of: " ▸ ", with: "\n  ▸ ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
