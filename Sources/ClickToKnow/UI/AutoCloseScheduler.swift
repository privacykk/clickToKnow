import Foundation

/// 自动关闭倒计时的延时器抽象（生产 = 主队列 asyncAfter，测试 = 记录调用）
@MainActor
protocol AutoCloseTimer {
    /// 取消上一个尚未触发的计时
    func cancel()
    /// 延时触发（调用方保证已 cancel 过）
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

/// 生产实现：主队列延时任务
@MainActor
final class DispatchAutoCloseTimer: AutoCloseTimer {
    private var item: DispatchWorkItem?

    func cancel() {
        item?.cancel()
        item = nil
    }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        self.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}

/// 自动关闭状态机：悬停即冻结倒计时，移开重新计时。
///
/// 抽出来的原因：原先「悬停取消定时器」在 `hoverChanged`、「排定定时器」在 `show()`，
/// 两者之间没有 `isHovering` 状态。流式释义每个增量都会整份调用 `show()`，
/// 于是每帧都无条件重排一次倒计时——悬停冻结被立刻覆盖，长流式内容在鼠标悬停时照样关闭。
/// 现在排定倒计时只有一个入口，且悬停期间直接拒绝排定。
@MainActor
final class AutoCloseScheduler {
    private let timer: AutoCloseTimer
    /// 鼠标当前是否停在弹窗上
    private(set) var isHovering = false
    private(set) var isPinned = false
    private var isActive = false
    private(set) var duration: TimeInterval

    /// 倒计时到点回调（ResultPopover 据此关闭面板）
    var onFire: (() -> Void)?

    init(timer: AutoCloseTimer? = nil, duration: TimeInterval = 15) {
        // 默认实现延迟到 init 内构造：默认参数在非隔离上下文求值，无法创建主 actor 隔离实例
        self.timer = timer ?? DispatchAutoCloseTimer()
        self.duration = duration
    }

    /// 开始/重排倒计时（首次展示与内容更新时调用；悬停中不排）
    func restart(duration: TimeInterval) {
        self.duration = duration
        isActive = true
        arm()
    }

    /// 鼠标进入/离开弹窗：进入即冻结，离开重新计时
    func hoverChanged(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering { timer.cancel() } else { arm() }
    }

    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        arm()
    }

    /// 关闭弹窗时清理计时
    func invalidate() {
        isActive = false
        isHovering = false
        isPinned = false
        timer.cancel()
    }

    /// 排定倒计时；悬停期间一律不排——「悬停暂停」的全部实现就在这里
    private func arm() {
        timer.cancel()
        guard isActive, !isHovering, !isPinned else { return }
        timer.schedule(after: duration) { [weak self] in
            self?.onFire?()
        }
    }
}
