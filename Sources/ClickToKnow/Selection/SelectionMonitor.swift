import AppKit
import Carbon.HIToolbox

/// 监听全局快捷键，抓取前台应用当前选中的文本。
/// 流程：记录鼠标位置 → 保存剪贴板快照 → 模拟 ⌘C → 轮询 changeCount → 读剪贴板 → 条件恢复 → 回调(文本, 位置)。
@MainActor
final class SelectionMonitor {
    private let hotKey = GlobalHotKey()
    private let clipboard = ClipboardManager()
    private let onSelected: (String, NSPoint) -> Void

    init(onSelected: @escaping (String, NSPoint) -> Void) {
        self.onSelected = onSelected
    }

    func start() {
        // 默认 ⌥⌘K（⌥⌘D 与系统「显示/隐藏 Dock」冲突）
        let ok = hotKey.register(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            self?.handleHotKey()
        }
        if ok {
            NSLog("[ClickToKnow] 快捷键 ⌥⌘K 已注册：选中文字后按下即可抓取")
        } else {
            NSLog("[ClickToKnow] 全局快捷键 ⌥⌘K 注册失败")
        }
    }

    private func handleHotKey() {
        let mouse = NSEvent.mouseLocation
        let initialCount = clipboard.saveSnapshot()
        simulateCopy()
        pollRead(initialCount: initialCount, deadline: Date().addingTimeInterval(0.5), mouse: mouse)
    }

    private func pollRead(initialCount: Int, deadline: Date, mouse: NSPoint) {
        if clipboard.changeCount != initialCount {
            let text = clipboard.readText()?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let readCount = clipboard.changeCount
            clipboard.restoreSnapshot(readChangeCount: readCount)
            guard !text.isEmpty else {
                NSLog("[ClickToKnow] 未抓取到文本（空选择）")
                return
            }
            onSelected(text, mouse)
        } else if Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.pollRead(initialCount: initialCount, deadline: deadline, mouse: mouse)
            }
        } else {
            clipboard.restoreSnapshot(readChangeCount: clipboard.changeCount)
            NSLog("[ClickToKnow] 未抓取到文本（超时，请确认已选中文字并授予辅助功能权限）")
        }
    }

    /// 向前台应用发送 ⌘C（需辅助功能权限，否则静默失败）。
    private func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }
}