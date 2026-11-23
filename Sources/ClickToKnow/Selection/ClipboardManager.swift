import AppKit

/// 剪贴板快照保存与条件恢复。
/// 选词抓取会触发 ⌘C，为避免污染用户原有剪贴板，抓取前深拷贝快照，读取结束后条件恢复。
@MainActor
final class ClipboardManager {
    private var backup: [NSPasteboardItem] = []
    private var hasBackup = false

    /// 当前剪贴板写入计数（每次写入自增），用作"复制是否生效"的基线对比
    var changeCount: Int { NSPasteboard.general.changeCount }

    /// 保存剪贴板快照，返回基线 changeCount（供轮询判断复制是否生效）。
    func saveSnapshot() -> Int {
        let pb = NSPasteboard.general
        backup = deepCopy(pb.pasteboardItems ?? [])
        hasBackup = true
        return pb.changeCount
    }

    /// 读取剪贴板纯文本（模拟 ⌘C 后取词的唯一数据源）
    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// 条件恢复：仅当当前 changeCount 与"读取文本那一刻"一致时才覆盖，避免覆盖第三方后续写入。
    func restoreSnapshot(readChangeCount: Int, delay: TimeInterval = 0.3) {
        guard hasBackup else { return }
        let items = backup
        hasBackup = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pb = NSPasteboard.general
            guard pb.changeCount == readChangeCount else { return }
            pb.clearContents()
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// 逐 type 深拷贝，避免 `pasteboardItems` 在多进程同时写入时竞态崩溃。
    private func deepCopy(_ items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}