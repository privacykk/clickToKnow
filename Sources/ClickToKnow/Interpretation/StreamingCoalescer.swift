import Foundation

/// 延时调度抽象（测试注入记录型实现，直接手动触发，不必等真实时间流逝）
@MainActor
protocol DelayScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

/// 生产实现：主队列 asyncAfter。
/// 包成 DispatchWorkItem 而不是直接传闭包：直接传会触发「非 Sendable 闭包」警告，
/// 而这条路径本来就是精确的主队列延时，没必要为消除警告改成 Task.sleep 牺牲时序精度。
@MainActor
final class MainQueueDelayScheduler: DelayScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: DispatchWorkItem(block: work))
    }
}

/// 流式增量的合并器：把高频 SSE delta 压到「每个窗口最多一次」渲染。
///
/// 每个 delta 都做一次全量 Markdown 解析 + 排版测高 + 窗口定位，长内容下这些都是主线程开销。
/// 合并策略：距上次交付已超过 `minInterval` 就立即交付最新文本，否则挂一个到期定时器，
/// 到期只交付「那一刻最新的」文本——中间的中间态直接丢弃。
///
/// 时间源与调度器都可注入，因此不必等真实流式响应就能断言合并行为。
@MainActor
final class StreamingCoalescer {
    /// 两次渲染的最小间隔（默认 50ms ≈ 20fps；短释义规模下人眼已看不出跳变）
    private let minInterval: TimeInterval
    private let now: () -> TimeInterval
    private let scheduler: DelayScheduling
    /// 交付动作（调用方负责渲染与上屏）
    private let deliver: (String) -> Void

    /// 最近一次收到但尚未交付的文本
    private var pending: String?
    /// 是否已挂了一个等待中的定时器
    private var flushScheduled = false
    /// 上次交付时刻
    private var lastDelivery: TimeInterval

    /// - Parameters:
    ///   - minInterval: 最小渲染间隔
    ///   - now: 单调时间源（默认 systemUptime，不受系统时钟调整影响）
    ///   - scheduler: 延时调度器
    ///   - deliver: 交付最新文本（在主 actor 调用）
    init(
        minInterval: TimeInterval = 0.05,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        scheduler: DelayScheduling? = nil,
        deliver: @escaping (String) -> Void
    ) {
        self.minInterval = max(minInterval, 0)
        self.now = now
        self.scheduler = scheduler ?? MainQueueDelayScheduler()
        self.deliver = deliver
        // 首次增量无需等待，应立刻出字
        self.lastDelivery = -minInterval
    }

    /// 收到一个增量（累积正文，非单片）
    func push(_ text: String) {
        pending = text
        let elapsed = now() - lastDelivery
        if elapsed >= minInterval {
            flush()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        scheduler.schedule(after: minInterval - elapsed) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            // 到点时可能已经被一次立即交付清空
            guard self.pending != nil else { return }
            self.flush()
        }
    }

    /// 立刻交付挂起的最新文本（流式结束或需要保证末帧落地时调用）
    func flush() {
        guard let text = pending else { return }
        pending = nil
        lastDelivery = now()
        deliver(text)
    }

    /// 是否有尚未交付的文本
    var hasPending: Bool { pending != nil }
}