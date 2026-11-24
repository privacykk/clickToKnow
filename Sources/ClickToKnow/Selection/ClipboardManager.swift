import AppKit

/// 剪贴板访问抽象：抓取兜底的事务语义在这里定义，SelectionMonitor 只编排顺序。
/// 抽出来是为了能在不碰真实剪贴板的前提下测「互斥何时释放」这条曾经的竞态路径。
@MainActor
protocol PasteboardAccess {
    /// 当前写入计数（每次写入自增），用作「复制是否生效」的基线
    var changeCount: Int { get }
    /// 保存深拷贝快照并返回基线 changeCount
    func saveSnapshot() -> Int
    /// 读纯文本（模拟 ⌘C 后取词的唯一数据源）
    func readText() -> String?
    /// 恢复快照：仅当 changeCount 仍等于 readChangeCount 时写入，避免覆盖第三方后续写入。
    /// **无论恢复还是放弃，都会回调**——调用方据此释放事务互斥。
    func restoreSnapshot(readChangeCount: Int, completion: @escaping (Bool) -> Void)
    /// 放弃恢复（快照直接丢弃，不写回剪贴板）
    func abandonSnapshot()
    /// 是否仍有未决快照
    var hasSnapshot: Bool { get }
}

/// 剪贴板快照保存与条件恢复。
/// 选词抓取会触发 ⌘C，为避免污染用户原有剪贴板，抓取前深拷贝快照，读取结束后条件恢复。
@MainActor
final class ClipboardManager: PasteboardAccess {
    private var backup: [NSPasteboardItem] = []
    private var hasBackup = false
    /// 恢复延迟：给目标应用写完剪贴板留出余量，太早恢复可能与它的第二次写入交错
    private let restoreDelay: TimeInterval

    init(restoreDelay: TimeInterval = 0.3) {
        self.restoreDelay = restoreDelay
    }

    /// 当前剪贴板写入计数
    var changeCount: Int { NSPasteboard.general.changeCount }

    /// 是否有未决快照
    var hasSnapshot: Bool { hasBackup }

    /// 保存剪贴板快照，返回基线 changeCount（供轮询判断复制是否生效）
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

    /// 条件恢复：仅当 changeCount 与「读取文本那一刻」一致时才覆盖。
    /// 完成（或因为第三方写入而放弃）后回调，事务互斥由调用方在回调里释放——
    /// 这就是此前 `finish()` 提前放锁、导致第二次查询把已复制的词条当原始剪贴板的修复点。
    func restoreSnapshot(readChangeCount: Int, completion: @escaping (Bool) -> Void) {
        guard hasBackup else {
            completion(false)
            return
        }
        let items = backup
        hasBackup = false
        backup = []
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            let pb = NSPasteboard.general
            // 期间有第三方写入：保留它的内容，不覆盖
            guard pb.changeCount == readChangeCount else {
                completion(false)
                return
            }
            pb.clearContents()
            if !items.isEmpty { pb.writeObjects(items) }
            completion(true)
        }
    }

    /// 放弃恢复：快照直接丢弃（剪贴板里留下的是本次复制的内容，需要调用方权衡）
    func abandonSnapshot() {
        hasBackup = false
        backup = []
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