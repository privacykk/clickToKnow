import XCTest

@testable import ClickToKnow

/// 流式增量合并（评审性能项 1）：每个 delta 都全量解析 Markdown + 测高 + 定位，
/// 长内容下都是主线程开销；合并后每窗口最多渲染一次，且末帧必须落地。
@MainActor
final class StreamingCoalescerTests: XCTestCase {
    /// 记录挂起的延时任务：记下绝对到期时刻，测试按虚拟时钟推进后只触发「确实到点」的任务
    private final class FakeScheduler: DelayScheduling {
        private(set) var pending: [(due: TimeInterval, work: () -> Void)] = []
        /// 虚拟时钟（由用例提供）
        var now: () -> TimeInterval = { 0 }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            pending.append((now() + delay, work))
        }

        /// 触发最早挂起的任务
        @discardableResult
        func fireNext() -> Bool {
            guard !pending.isEmpty else { return false }
            let next = pending.removeFirst()
            next.work()
            return true
        }

        /// 只触发已到期的任务（按虚拟时钟）
        func fireDue() {
            while let index = pending.firstIndex(where: { $0.due <= now() }) {
                let next = pending.remove(at: index)
                next.work()
            }
        }
    }

    private var clock: TimeInterval = 0
    private var delivered: [String] = []
    private var scheduler: FakeScheduler!

    override func setUp() {
        super.setUp()
        clock = 0
        delivered = []
        scheduler = FakeScheduler()
        scheduler.now = { [unowned self] in self.clock }
    }

    private func makeCoalescer(minInterval: TimeInterval = 0.05) -> StreamingCoalescer {
        StreamingCoalescer(
            minInterval: minInterval,
            now: { [unowned self] in self.clock },
            scheduler: scheduler,
            deliver: { [unowned self] text in self.delivered.append(text) }
        )
    }

    /// 首个增量立即交付：不能让用户等一个窗口才看到第一个字
    func test_firstDeltaDeliveredImmediately() {
        let coalescer = makeCoalescer()
        coalescer.push("he")
        XCTAssertEqual(delivered, ["he"])
        XCTAssertFalse(coalescer.hasPending, "立即交付后不应残留挂起文本")
    }

    /// 窗口内的后续增量被合并：只在窗口到期时交付，且只交付最新文本
    func test_deltasWithinWindowAreCoalesced() {
        let coalescer = makeCoalescer()
        coalescer.push("a")          // 立即交付
        clock += 0.01
        coalescer.push("ab")         // 窗口内 → 挂起
        clock += 0.01
        coalescer.push("abc")        // 仍然只更新挂起值，不重复挂定时器
        XCTAssertEqual(delivered, ["a"])
        XCTAssertTrue(coalescer.hasPending)
        XCTAssertEqual(scheduler.pending.count, 1, "同一窗口只挂一个定时器")

        clock += 0.04                  // 到点
        scheduler.fireNext()
        XCTAssertEqual(delivered, ["a", "abc"], "中间态 ab 被丢弃，只交付最新文本")
        XCTAssertFalse(coalescer.hasPending)
    }

    /// 窗口外的增量再次立即交付
    func test_deltaOutsideWindowDeliveredImmediately() {
        let coalescer = makeCoalescer()
        coalescer.push("a")
        clock += 0.06
        coalescer.push("ab")
        XCTAssertEqual(delivered, ["a", "ab"])
    }

    /// 流式结束的 flush 必须把最后一帧补上（否则末帧会停在半句话）
    func test_flushDeliversPendingFinalFrame() {
        let coalescer = makeCoalescer()
        coalescer.push("a")
        clock += 0.01
        coalescer.push("ab")
        coalescer.flush()
        XCTAssertEqual(delivered, ["a", "ab"])
        XCTAssertFalse(coalescer.hasPending)

        // 没有挂起内容时 flush 不应重复交付
        coalescer.flush()
        XCTAssertEqual(delivered, ["a", "ab"])
    }

    /// 定时器到点时挂起值已被立即交付清空 → 不重复交付
    func test_expiredTimerAfterImmediateDeliveryDoesNothing() {
        let coalescer = makeCoalescer()
        coalescer.push("a")          // 立即交付，清空 pending
        clock += 0.01
        coalescer.push("ab")         // 挂一个定时器
        clock += 0.06
        coalescer.push("abc")        // 距上次交付已够久 → 立即交付并清空
        XCTAssertEqual(delivered, ["a", "abc"])

        scheduler.fireNext()         // 旧定时器到点，pending 已空
        XCTAssertEqual(delivered, ["a", "abc"], "不得重复交付同一份文本")
    }

    /// 高频增量（100 个 delta / 50ms 窗口）应只产生个位数渲染
    func test_burstIsCoalescedToFewRenders() {
        let coalescer = makeCoalescer()
        var text = ""
        for index in 0..<100 {
            clock += 0.001            // 1ms 一个 delta
            text += "字\(index)"
            coalescer.push(text)
            scheduler.fireDue()       // 只有真正到点的定时器才触发
        }
        coalescer.flush()
        XCTAssertLessThan(delivered.count, 10, "100 个 delta 不应产生 100 次渲染")
        XCTAssertEqual(delivered.last, text, "末帧必须是完整文本")
    }
}