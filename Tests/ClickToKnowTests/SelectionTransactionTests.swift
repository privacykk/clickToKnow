import AppKit
import XCTest

@testable import ClickToKnow

/// 取词事务（评审问题 5 / 6）：
/// - AX 读取异步化后，主线程不再同步等待，结果过期即丢弃；
/// - 剪贴板兜底是事务，互斥要一直持有到快照恢复完成。
///
/// 通过注入假 AX 读取器、假剪贴板、假延时器与假环境，无需辅助功能授权即可覆盖这些路径。
@MainActor
final class SelectionTransactionTests: XCTestCase {
    // MARK: - 测试替身

    private final class FakeReader: SelectionReading {
        var results: [AXSelectionReader.Result?] = []
        private(set) var readCount = 0
        /// 读取时触发的副作用（模拟「等待 AX 期间用户切走了应用」）
        var onRead: (() -> Void)?

        func read() async -> AXSelectionReader.Result? {
            readCount += 1
            onRead?()
            return results.isEmpty ? nil : results.removeFirst()
        }
    }

    private final class FakePasteboard: PasteboardAccess {
        var changeCount = 100
        var text: String?
        /// 快照内容（用于断言「把复制的词条当成原始剪贴板」这类污染）
        private(set) var snapshotText: String?
        private(set) var saveCount = 0
        private(set) var restoreCount = 0
        private(set) var abandonCount = 0
        private var pendingCompletion: ((Bool) -> Void)?
        /// false = 恢复延迟到测试显式完成（模拟 300ms 恢复窗口）
        var autoCompleteRestore = true
        private(set) var hasSnapshot = false

        func saveSnapshot() -> Int {
            saveCount += 1
            snapshotText = text
            hasSnapshot = true
            return changeCount
        }

        func readText() -> String? { text }

        func restoreSnapshot(readChangeCount: Int, completion: @escaping (Bool) -> Void) {
            restoreCount += 1
            hasSnapshot = false
            if autoCompleteRestore {
                completion(true)
            } else {
                pendingCompletion = completion
            }
        }

        func abandonSnapshot() {
            abandonCount += 1
            hasSnapshot = false
        }

        /// 模拟目标应用写入剪贴板（模拟 ⌘C 生效）
        func simulateCopyWrite(_ newText: String) {
            text = newText
            changeCount += 1
        }

        /// 模拟 300ms 恢复窗口结束
        func completeRestore() {
            let completion = pendingCompletion
            pendingCompletion = nil
            completion?(true)
        }
    }

    private final class FakeScheduler: DelayScheduling {
        private(set) var pending: [(delay: TimeInterval, work: () -> Void)] = []

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            pending.append((delay, work))
        }

        @discardableResult
        func runNext() -> Bool {
            guard !pending.isEmpty else { return false }
            let next = pending.removeFirst()
            next.work()
            return true
        }
    }

    /// 可控时钟：轮询截止判断依赖它
    private final class Clock {
        var current = Date(timeIntervalSinceReferenceDate: 0)
        func advance(_ seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    private var reader: FakeReader!
    private var pasteboard: FakePasteboard!
    private var scheduler: FakeScheduler!
    private var clock: Clock!
    private var selected: [(text: String, context: String?)] = []
    private var failures: [SelectionFailure] = []

    /// 可变环境：默认一切正常，用例按需改写
    private var accessibilityTrusted = true
    private var secureInput = false
    private var frontmostPID: pid_t? = 4242
    private var frontmostBundleID: String? = "com.example.editor"
    /// 事务期间「用户按下 ⌘C」的模拟回调（由被测对象注册，事务结束应注销）
    private var userCopyHandler: (() -> Void)?

    override func setUp() {
        super.setUp()
        reader = FakeReader()
        pasteboard = FakePasteboard()
        scheduler = FakeScheduler()
        clock = Clock()
        selected = []
        failures = []
        accessibilityTrusted = true
        secureInput = false
        frontmostPID = 4242
        frontmostBundleID = "com.example.editor"
        userCopyHandler = nil
    }

    /// simulateCopy 缺省模拟「⌘C 复制出了 helm」
    private func makeMonitor(simulateCopy: (() -> Void)? = nil) -> SelectionMonitor {
        var environment = SelectionMonitor.Environment.live
        environment.isAccessibilityTrusted = { [unowned self] in self.accessibilityTrusted }
        environment.isSecureInputEnabled = { [unowned self] in self.secureInput }
        environment.frontmostPID = { [unowned self] in self.frontmostPID }
        environment.frontmostBundleID = { [unowned self] in self.frontmostBundleID }
        environment.blacklistedBundleIDs = { ["com.1password.1password"] }
        environment.mouseLocation = { NSPoint(x: 100, y: 200) }
        environment.simulateCopy = simulateCopy ?? { [unowned self] in
            self.pasteboard.simulateCopyWrite("helm")
        }
        environment.observeUserCopyKeyPress = { [unowned self] handler in
            self.userCopyHandler = handler
            return { [unowned self] in self.userCopyHandler = nil }
        }
        return SelectionMonitor(
            onSelected: { [unowned self] text, _, context in
                self.selected.append((text, context))
            },
            onFailure: { [unowned self] failure, _ in
                self.failures.append(failure)
            },
            reader: reader,
            pasteboard: pasteboard,
            environment: environment,
            scheduler: scheduler,
            now: { [unowned self] in self.clock.current }
        )
    }

    // MARK: - 问题 5：AX 异步与过期结果

    /// AX 直读成功：不打剪贴板、互斥在使用后释放
    func test_axPathDeliversWithoutTouchingPasteboard() async {
        reader.results = [AXSelectionReader.Result(text: "helm", rect: nil, context: "k8s context")]
        let monitor = makeMonitor()

        await monitor.performSelection()

        XCTAssertEqual(selected.count, 1)
        XCTAssertEqual(selected.first?.text, "helm")
        XCTAssertEqual(selected.first?.context, "k8s context")
        XCTAssertEqual(pasteboard.saveCount, 0, "AX 路径不应碰剪贴板")
        XCTAssertFalse(monitor.isProcessing, "取词结束后互斥必须释放")
        XCTAssertTrue(failures.isEmpty)
    }

    /// AX 选区矩形决定弹窗锚点（拿不到时回退鼠标位置）
    func test_axPathUsesSelectionRectAsAnchor() async {
        var capturedAnchor: NSPoint?
        var environment = SelectionMonitor.Environment.live
        environment.isAccessibilityTrusted = { true }
        environment.isSecureInputEnabled = { false }
        environment.frontmostPID = { 4242 }
        environment.frontmostBundleID = { "com.example.editor" }
        environment.blacklistedBundleIDs = { [] }
        environment.mouseLocation = { NSPoint(x: 10, y: 20) }
        environment.simulateCopy = {}
        let monitor = SelectionMonitor(
            onSelected: { _, anchor, _ in capturedAnchor = anchor },
            reader: FakeReaderResult(AXSelectionReader.Result(
                text: "helm", rect: NSRect(x: 300, y: 400, width: 40, height: 12), context: nil
            )),
            pasteboard: pasteboard,
            environment: environment,
            scheduler: scheduler,
            now: { Date() }
        )
        await monitor.performSelection()
        XCTAssertEqual(capturedAnchor, NSPoint(x: 300, y: 412), "锚点应为选区左上角")
    }

    /// 无辅助功能权限：不进入读取，直接给可操作提示
    func test_missingAccessibilityPermissionFailsFast() async {
        accessibilityTrusted = false
        let monitor = makeMonitor()
        await monitor.performSelection()
        XCTAssertEqual(failures, [.noAccessibilityPermission])
        XCTAssertEqual(reader.readCount, 0)
    }

    /// 安全输入态：不读取、不复制
    func test_secureInputSkipsCapture() async {
        secureInput = true
        let monitor = makeMonitor()
        await monitor.performSelection()
        XCTAssertEqual(failures, [.secureInputActive])
        XCTAssertEqual(reader.readCount, 0)
    }

    /// 黑名单应用：永不抓取
    func test_blacklistedAppSkipsCapture() async {
        frontmostBundleID = "com.1password.1password"
        let monitor = makeMonitor()
        await monitor.performSelection()
        XCTAssertEqual(failures, [.blacklistedApp])
        XCTAssertEqual(reader.readCount, 0)
    }

    /// 核心回归：AX 等待期间前台应用已切换 → 不得再用 ⌘C 兜底（会复制到别处的内容）
    func test_targetSwitchDuringAXReadCancelsCopyFallback() async {
        reader.results = [nil]
        reader.onRead = { [unowned self] in
            // AX 读取期间用户切到了别的应用
            self.frontmostPID = 999
        }
        let monitor = makeMonitor()

        await monitor.performSelection()

        XCTAssertEqual(failures, [.targetChanged])
        XCTAssertEqual(pasteboard.saveCount, 0, "目标已切换时不得开始剪贴板事务")
        XCTAssertFalse(monitor.isProcessing)
    }

    /// 等待期间进入安全输入态 → 同样取消兜底
    func test_secureInputDuringAXReadCancelsCopyFallback() async {
        reader.results = [nil]
        reader.onRead = { [unowned self] in self.secureInput = true }
        let monitor = makeMonitor()

        await monitor.performSelection()

        XCTAssertEqual(failures, [.secureInputActive])
        XCTAssertEqual(pasteboard.saveCount, 0)
    }

    // MARK: - 问题 6：剪贴板事务与互斥释放时机

    /// 核心回归：恢复窗口内互斥必须仍然持有。
    /// 旧实现在排程恢复后就 finish()，第二次查询能抢在恢复前保存快照，
    /// 把第一次复制的词条当成「用户原始剪贴板」，最终把剪贴板污染成第一个查过的词。
    func test_mutexHeldUntilSnapshotRestored() async {
        reader.results = [nil]
        pasteboard.autoCompleteRestore = false
        pasteboard.text = "用户原有的剪贴板内容"
        let monitor = makeMonitor()

        await monitor.performSelection()
        XCTAssertEqual(selected.first?.text, "helm")
        XCTAssertEqual(pasteboard.restoreCount, 1)
        XCTAssertTrue(monitor.isProcessing, "快照未恢复前不得释放互斥")

        // 第二次按键落在恢复窗口内：必须被丢弃
        reader.results = [nil]
        pasteboard.text = "helm"
        await monitor.performSelection()
        XCTAssertEqual(selected.count, 1, "恢复窗口内的第二次查询应被丢弃")
        XCTAssertEqual(pasteboard.saveCount, 1, "不得保存第二份「快照」覆盖用户原始剪贴板")
        XCTAssertEqual(pasteboard.snapshotText, "用户原有的剪贴板内容", "快照内容不得被本次复制的词条污染")

        // 恢复完成 → 互斥释放 → 下一次查询正常进行
        pasteboard.completeRestore()
        XCTAssertFalse(monitor.isProcessing)

        pasteboard.text = "用户原有的剪贴板内容"
        pasteboard.changeCount += 10
        reader.results = [nil]
        await monitor.performSelection()
        XCTAssertEqual(selected.count, 2, "恢复完成后应能再次取词")
    }

    /// 空选择：仍要恢复剪贴板，并如实报告空选择
    func test_emptySelectionRestoresSnapshotAndReports() async {
        reader.results = [nil]
        pasteboard.autoCompleteRestore = false
        pasteboard.text = "原内容"
        // 模拟 ⌘C 后目标应用写入空内容
        let monitor = makeMonitor(simulateCopy: { [unowned self] in self.pasteboard.simulateCopyWrite("") })

        await monitor.performSelection()

        XCTAssertEqual(failures, [.emptySelection])
        XCTAssertEqual(pasteboard.restoreCount, 1, "空选择也要恢复快照")
        XCTAssertTrue(monitor.isProcessing)
        pasteboard.completeRestore()
        XCTAssertFalse(monitor.isProcessing)
    }

    /// 超时：轮询到截止仍无变化 → 恢复快照、报告超时、恢复完成后释放互斥
    func test_timeoutRestoresAndReports() async {
        reader.results = [nil]
        pasteboard.autoCompleteRestore = false
        pasteboard.text = "原内容"
        // 模拟 ⌘C 完全无效：simulateCopy 不做任何事
        let monitor = makeMonitor(simulateCopy: {})

        // 第一次调用进入轮询（挂定时器）
        let task = Task { await monitor.performSelection() }
        await Task.yield()
        XCTAssertEqual(pasteboard.saveCount, 1)

        // 推进时钟超过 0.5s 预算并触发轮询
        clock.advance(SelectionMonitor.copyTimeout + 0.1)
        scheduler.runNext()
        await task.value

        XCTAssertEqual(failures, [.timeout])
        XCTAssertEqual(pasteboard.restoreCount, 1)
        pasteboard.completeRestore()
        XCTAssertFalse(monitor.isProcessing)
    }

    /// 暂停取词：在途结果作废，不得再把释义弹出来
    func test_pauseInvalidatesInFlightResult() async {
        let monitor = makeMonitor()
        // 用「读取期间暂停」模拟在途作废：AX 返回前代际已被 pause 改变
        reader.results = [AXSelectionReader.Result(text: "helm", rect: nil, context: nil)]
        reader.onRead = { monitor.setPaused(true) }

        await monitor.performSelection()

        XCTAssertTrue(selected.isEmpty, "暂停后旧结果不得交付")
        XCTAssertFalse(monitor.isProcessing, "作废也要释放互斥，否则此后永久无法取词")
    }

    /// 事务进行中被暂停：仍要恢复快照，但不得交出结果
    func test_pauseDuringClipboardTransactionRestoresWithoutDelivering() async {
        reader.results = [nil]
        pasteboard.autoCompleteRestore = false
        pasteboard.text = "原内容"
        // 模拟 ⌘C 尚未生效：第一次轮询看到 changeCount 未变，进入轮询等待
        let monitor = makeMonitor(simulateCopy: {})

        let task = Task { await monitor.performSelection() }
        await Task.yield()
        XCTAssertEqual(pasteboard.saveCount, 1, "事务已开始并保存快照")

        // 轮询期间用户暂停取词：代际变化
        monitor.setPaused(true)
        // 目标应用此刻才完成复制
        pasteboard.simulateCopyWrite("helm")
        scheduler.runNext()
        await task.value

        XCTAssertTrue(selected.isEmpty, "被取代的事务不得交付结果")
        XCTAssertEqual(pasteboard.restoreCount, 1, "但仍必须把用户剪贴板恢复回去")
        XCTAssertTrue(monitor.isProcessing, "恢复完成前不释放互斥")
        pasteboard.completeRestore()
        XCTAssertFalse(monitor.isProcessing)
    }

    /// 悬停状态由 AutoCloseScheduler 持有，内容更新不重排倒计时（见 AutoCloseSchedulerTests 覆盖）
    func test_monitorDoesNotTouchClipboardOnAXSuccess() async {
        reader.results = [AXSelectionReader.Result(text: "word", rect: nil, context: nil)]
        let monitor = makeMonitor()
        await monitor.performSelection()
        XCTAssertEqual(pasteboard.saveCount, 0)
        XCTAssertEqual(pasteboard.restoreCount, 0)
    }

    // MARK: - 交付前复核隐私条件

    /// AX 直读成功但等待期间前台应用已切换：结果不得交付
    func test_axResultDroppedWhenTargetSwitchesBeforeDelivery() async {
        reader.results = [AXSelectionReader.Result(text: "helm", rect: nil, context: nil)]
        reader.onRead = { [unowned self] in self.frontmostPID = 999 }
        let monitor = makeMonitor()

        await monitor.performSelection()

        XCTAssertTrue(selected.isEmpty, "交付前必须复核前台应用，切走后不得交出结果")
        XCTAssertEqual(failures, [.targetChanged])
        XCTAssertFalse(monitor.isProcessing, "作废也要释放互斥")
    }

    /// AX 直读成功但等待期间目标被加入禁止名单：结果不得交付
    func test_axResultDroppedWhenTargetBecomesBlacklisted() async {
        reader.results = [AXSelectionReader.Result(text: "helm", rect: nil, context: nil)]
        reader.onRead = { [unowned self] in self.frontmostBundleID = "com.1password.1password" }
        let monitor = makeMonitor()

        await monitor.performSelection()

        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(failures, [.blacklistedApp])
    }

    /// AX 直读成功但等待期间进入安全输入态：结果不得交付
    func test_axResultDroppedWhenSecureInputTurnsOnBeforeDelivery() async {
        reader.results = [AXSelectionReader.Result(text: "helm", rect: nil, context: nil)]
        reader.onRead = { [unowned self] in self.secureInput = true }
        let monitor = makeMonitor()

        await monitor.performSelection()

        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(failures, [.secureInputActive])
    }

    // MARK: - 剪贴板兜底不误用/不覆盖用户复制

    /// 核心回归：事务期间用户自己按 ⌘C 复制了内容 ——
    /// 既不得把它当成选词去查询，也不得用旧快照覆盖用户的新内容。
    func test_userCopyDuringTransactionIsNeitherQueriedNorOverwritten() async {
        reader.results = [nil]
        pasteboard.text = "用户原有内容"
        // 模拟 ⌘C 尚未生效：第一次轮询看不到变化，进入轮询等待
        let monitor = makeMonitor(simulateCopy: {})
        let task = Task { await monitor.performSelection() }
        await Task.yield()
        XCTAssertEqual(pasteboard.saveCount, 1, "事务已开始")
        XCTAssertNotNil(userCopyHandler, "事务期间应监听用户手动 ⌘C")

        userCopyHandler?() // 用户按了 ⌘C
        pasteboard.simulateCopyWrite("用户手动复制的内容")
        scheduler.runNext()
        await task.value

        XCTAssertTrue(selected.isEmpty, "用户手动复制的内容不得被当成选词")
        XCTAssertEqual(pasteboard.abandonCount, 1, "不得恢复旧快照覆盖用户新内容")
        XCTAssertEqual(pasteboard.restoreCount, 0)
        XCTAssertEqual(failures, [.clipboardChangedExternally])
        XCTAssertFalse(monitor.isProcessing)
        XCTAssertNil(userCopyHandler, "事务结束必须注销全局键监听")
    }

    /// 复制期间前台应用已切换：结果仍要恢复剪贴板，但不得交付
    func test_targetSwitchDuringClipboardWaitDropsResultAndRestores() async {
        reader.results = [nil]
        pasteboard.text = "原内容"
        pasteboard.autoCompleteRestore = false
        let monitor = makeMonitor(simulateCopy: { [unowned self] in
            self.pasteboard.simulateCopyWrite("helm")
            self.frontmostPID = 999 // 复制生效后用户切走了应用
        })

        await monitor.performSelection()

        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(failures, [.targetChanged])
        XCTAssertEqual(pasteboard.restoreCount, 1, "结果不交付也要把用户剪贴板恢复回去")
        XCTAssertTrue(monitor.isProcessing, "恢复完成前不释放互斥")
        pasteboard.completeRestore()
        XCTAssertFalse(monitor.isProcessing)
    }

    /// 固定返回单个结果的读取器（锚点用例用）
    private struct FakeReaderResult: SelectionReading {
        let result: AXSelectionReader.Result
        init(_ result: AXSelectionReader.Result) { self.result = result }
        func read() async -> AXSelectionReader.Result? { result }
    }
}