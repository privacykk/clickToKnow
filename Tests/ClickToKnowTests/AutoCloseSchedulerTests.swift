import XCTest

@testable import ClickToKnow

/// 自动关闭倒计时（评审问题 7）：悬停必须真的冻结倒计时，
/// 而流式内容更新不得把冻结覆盖掉。
@MainActor
final class AutoCloseSchedulerTests: XCTestCase {
    /// 记录延时任务；`cancel` 只清掉未触发项
    private final class FakeTimer: AutoCloseTimer {
        private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        private(set) var cancelCount = 0
        private(set) var firedCount = 0

        func cancel() {
            cancelCount += 1
            scheduled.removeAll()
        }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduled.append((delay, work))
        }

        /// 触发最早挂起的任务（模拟倒计时到点）
        func fire() {
            guard !scheduled.isEmpty else { return }
            let next = scheduled.removeFirst()
            firedCount += 1
            next.work()
        }
    }

    private var timer: FakeTimer!
    private var scheduler: AutoCloseScheduler!
    private var fired = false

    override func setUp() {
        super.setUp()
        timer = FakeTimer()
        scheduler = AutoCloseScheduler(timer: timer, duration: 15)
        fired = false
        scheduler.onFire = { [unowned self] in self.fired = true }
    }

    /// 正常倒计时：到点触发关闭
    func test_firesWhenTimerExpires() {
        scheduler.restart(duration: 15)
        XCTAssertEqual(timer.scheduled.count, 1)
        XCTAssertEqual(timer.scheduled.first?.delay, 15)
        timer.fire()
        XCTAssertTrue(fired)
    }

    /// 悬停冻结：进入悬停后不得存在未触发的倒计时
    func test_hoverCancelsCountdown() {
        scheduler.restart(duration: 15)
        scheduler.hoverChanged(true)
        XCTAssertTrue(scheduler.isHovering)
        XCTAssertTrue(timer.scheduled.isEmpty, "悬停期间不应有未触发的倒计时")
    }

    /// 核心回归：悬停期间内容更新（restart）不得重新排定倒计时。
    /// 旧实现在每个流式增量都 show() → 重排定时器，于是悬停冻结被逐帧覆盖。
    func test_restartWhileHoveringDoesNotArm() {
        scheduler.restart(duration: 25)
        scheduler.hoverChanged(true)
        for _ in 0..<10 {
            scheduler.restart(duration: 25) // 模拟 10 个流式增量
        }
        XCTAssertTrue(timer.scheduled.isEmpty, "悬停中的内容更新不得恢复倒计时")
        XCTAssertTrue(scheduler.isHovering)
    }

    /// 移开鼠标后重新计时，且沿用最新时限
    func test_unhoverResumesWithLatestDuration() {
        scheduler.restart(duration: 15)
        scheduler.hoverChanged(true)
        scheduler.restart(duration: 25) // 悬停期间换成了更长的时限
        scheduler.hoverChanged(false)
        XCTAssertFalse(scheduler.isHovering)
        XCTAssertEqual(timer.scheduled.count, 1)
        XCTAssertEqual(timer.scheduled.first?.delay, 25)
    }

    /// 重复进入/离开不重复排定（mouseEntered 可能多次触发）
    func test_repeatedHoverEventsAreIdempotent() {
        scheduler.restart(duration: 15)
        scheduler.hoverChanged(true)
        scheduler.hoverChanged(true)
        XCTAssertTrue(timer.scheduled.isEmpty)

        scheduler.hoverChanged(false)
        scheduler.hoverChanged(false)
        XCTAssertEqual(timer.scheduled.count, 1, "离开只应排一次")
    }

    /// 关闭弹窗后清理计时，不得再触发 onFire
    func test_invalidateStopsFiring() {
        scheduler.restart(duration: 15)
        scheduler.invalidate()
        XCTAssertTrue(timer.scheduled.isEmpty)
        timer.fire() // 没东西可触发
        XCTAssertFalse(fired)
    }
}