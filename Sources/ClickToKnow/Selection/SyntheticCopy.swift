import AppKit
import Carbon.HIToolbox

/// 模拟 ⌘C 的投递与识别。
///
/// 取词兜底必须模拟一次复制，但事务期间用户完全可能自己按下 ⌘C。两者都会改变剪贴板，
/// 只看 changeCount 分不清「目标应用复制出的选区」和「用户刚复制的内容」：
/// 把用户内容当成选词发送出去会泄露不该发送的文字，恢复快照时又会把它覆盖掉。
///
/// 这里的做法是给合成事件打上行内标记（`eventSourceUserData`），全局键监听据此把自己的
/// 投递筛掉，剩下的 ⌘C 才是用户按的。标记未随事件传播时（例如输入法或远程桌面重投递），
/// 再按「投递时刻与事件时间戳是否接近」兜底判断。
final class SyntheticCopy: @unchecked Sendable {
    static let shared = SyntheticCopy()

    /// 合成事件标记（ASCII "CTKC"）；只用于区分来源，不携带任何用户数据
    static let eventUserData: Int64 = 0x43544B43

    /// 事件时间戳与本进程投递时刻的容差：合成事件通常在数十毫秒内到达焦点应用
    private static let timestampTolerance: TimeInterval = 0.2

    private let lock = NSLock()
    /// 最近一次投递合成 ⌘C 的时刻（systemUptime 秒）；从未投递过时为 0
    private var lastPostedAt: TimeInterval = 0

    /// 向前台应用投递一次 ⌘C（按下 + 抬起）
    static func postCommandC() {
        shared.post()
    }

    /// 全局键监听收到的 ⌘C 是否由本进程投递（true = 忽略，剩下的才是用户手动复制）。
    /// 可能从非主线程的监听回调调用，状态用锁保护。
    static func isSynthetic(_ event: NSEvent) -> Bool {
        if let cgEvent = event.cgEvent,
           cgEvent.getIntegerValueField(.eventSourceUserData) == eventUserData {
            return true
        }
        return shared.recentlyPosted(event.timestamp)
    }

    private func post() {
        let postedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        lastPostedAt = postedAt
        lock.unlock()
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_C),
                keyDown: keyDown
            ) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: Self.eventUserData)
            event.post(tap: .cghidEventTap)
        }
    }

    private func recentlyPosted(_ timestamp: TimeInterval) -> Bool {
        lock.lock()
        let postedAt = lastPostedAt
        lock.unlock()
        guard postedAt > 0 else { return false }
        return abs(timestamp - postedAt) < Self.timestampTolerance
    }
}