import AppKit
import AVFoundation
import NaturalLanguage

/// 就地悬浮展示释义的无边框面板：不抢焦点、浮于其它窗口之上、点击外部/超时自动关闭，
/// 鼠标悬停期间暂停倒计时（避免长内容读到一半被打断）。
/// 拖动：顶部有握把区（拖动即移动窗口），卡片内边距的空白同样可拖；
/// 用户拖动过之后，流式内容继续增长只改高度、不再把窗口拉回选区锚点。
@MainActor
final class ResultPopover: NSObject {
    /// 无边框不抢焦点的浮动面板
    private let panel: NSPanel
    /// 圆角容器（同时承担悬停检测与背景拖动）
    private let container: HoverDetectingView
    private let scrollView: NSScrollView
    /// 释义内容承载（Markdown 渲染结果直接设置）
    private let textView: NSTextView
    /// 顶部拖动握把（唯一稳定可见的移动入口）
    private let dragHandle = PopoverDragHandle()
    private let toolbar = NonDraggableStackView()
    private let copyButton = NSButton(title: "复制释义", target: nil, action: nil)
    private let speakButton = NSButton(title: "发音", target: nil, action: nil)
    private let pinButton = NSButton(title: "钉住", target: nil, action: nil)
    private let favoriteButton = NSButton(title: "收藏", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let closeButton = NSButton(title: "关闭", target: nil, action: nil)
    private let speech = AVSpeechSynthesizer()
    private var result: Interpretation?
    private var retry: (() -> Void)?
    private var toggleFavorite: (() -> Bool?)?
    /// 点击外部关闭的全局监视器
    private var dismissMonitor: Any?
    /// Esc 关闭的本地监视器（事件投递给本进程时生效）
    private var keyMonitor: Any?
    /// Esc 关闭的全局监视器（原应用保持焦点时唯一能收到 Esc 的途径）
    private var globalKeyMonitor: Any?
    /// 自动关闭状态机（悬停冻结 / 移开重排，唯一排定入口）
    private let autoClose = AutoCloseScheduler()
    /// 最近一次展示的锚点：内容更新时沿用它重新定位，弹窗不会因流式内容增多而跳走
    private var lastAnchor: NSPoint = .zero
    /// 用户拖动后的左上角（屏幕坐标）。非 nil 时内容更新沿用这个位置，只按新高度向下生长
    private var pinnedTopLeft: NSPoint?
    /// 正在按内容重排窗口（区分「程序化 setFrame」与「用户拖动」，避免把自己的布局当成手动位置）
    private var isProgrammaticMove = false

    /// 弹窗关闭时回调（点击外部 / 超时 / Esc）：AppDelegate 借此取消仍在进行的 LLM 请求，避免白烧 token
    var onClose: (() -> Void)?

    // 尺寸约束：内容超出最大高度转为滚动
    private static let maxWidth: CGFloat = 560
    private static let maxContentHeight: CGFloat = 500
    private static let padding: CGFloat = 16
    /// 顶部握把区高度与它与正文的间距（拖动入口，视觉上是一条居中的握把）
    private static let handleHeight: CGFloat = 14
    private static let handleSpacing: CGFloat = 6

    /// 组装面板、滚动视图、文本视图与悬停容器
    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating // kCGModalPanelWindowLevel，勿再升高以免盖住系统模态
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.animationBehavior = .utilityWindow
        // 卡片空白处按住即可拖动：无边框面板走 AppKit 的 background 拖动
        panel.isMovableByWindowBackground = true

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // 关键：手动用 containerSize 控制换行宽度，而不是被 textView.frame 覆盖
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView

        container = HoverDetectingView()
        super.init()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 0.5
        applyAppearance()
        container.onHover = { [weak self] hovering in
            self?.hoverChanged(hovering)
        }
        container.addSubview(scrollView)
        configureToolbar()
        container.addSubview(toolbar)
        dragHandle.toolTip = "按住拖动可移动弹窗"
        dragHandle.onDragRequest = { [weak self] event in
            self?.dragPanel(with: event)
        }
        container.addSubview(dragHandle)
        panel.contentView = container
        autoClose.onFire = { [weak self] in
            self?.close()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification, object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 跟随系统亮暗外观：cgColor 是快照，弹窗生命周期短（≤25s），每次展示时刷新一次即可
    private func applyAppearance() {
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        // 握把用动态颜色自绘，外观变化后需要重绘（弹窗不重建，只有这里能触发）
        dragHandle.needsDisplay = true
    }

    /// 首次展示（或切换到一条新内容）：定尺寸定位 → 装监视器 → 排倒计时 → 上屏。
    /// 流式增量请走 `updateContent`，否则每帧重装监视器与重排倒计时会把悬停暂停覆盖掉。
    func show(
        _ attributed: NSAttributedString, at mouse: NSPoint, autoCloseAfter: TimeInterval? = 15,
        result: Interpretation? = nil, retry: (() -> Void)? = nil, toggleFavorite: (() -> Bool?)? = nil
    ) {
        self.result = result
        self.retry = retry
        self.toggleFavorite = toggleFavorite
        copyButton.title = "复制释义"
        copyButton.isHidden = result == nil
        speakButton.isHidden = result == nil
        pinButton.isHidden = result == nil
        retryButton.isHidden = retry == nil
        favoriteButton.isHidden = toggleFavorite == nil
        favoriteButton.title = "收藏"
        speech.stopSpeaking(at: .immediate)
        autoClose.setPinned(false)
        pinButton.title = "钉住"
        lastAnchor = mouse
        // 注意：这里刻意不重置 pinnedTopLeft —— 同一次查询的流式收尾/失败提示也走 show，
        // 若在此清零，用户拖动过的弹窗会在结果落地那一刻被拽回选区。新查询由调用方
        // 先调 resetPlacement()（见 AppDelegate.handleSelectedText）。
        layout(attributed, at: mouse)
        addDismissMonitor()
        addKeyMonitor()
        autoClose.restart(duration: autoCloseAfter)
        panel.orderFront(nil)
        autoClose.hoverChanged(panel.frame.contains(NSEvent.mouseLocation))
    }

    /// 新一次查询开始：忘记用户拖动过的位置，重新贴回选区锚点。
    /// 与 show() 分开是因为「同一次查询的结果/失败提示」也会走 show，那时必须保留用户的拖动。
    func resetPlacement() {
        pinnedTopLeft = nil
    }

    /// 仅更新内容：沿用首次展示的锚点重排尺寸，不碰监视器、不重排倒计时。
    /// 增量可能非常密集（每个 SSE delta 一次），这里刻意保持最小动作。
    func updateContent(_ attributed: NSAttributedString) {
        guard panel.isVisible else { return }
        layout(attributed, at: lastAnchor)
    }

    /// 按固定宽度测高、定位并 clamp 进可视区（show 与 updateContent 共用）
    private func layout(_ attributed: NSAttributedString, at mouse: NSPoint) {
        applyAppearance()

        let pad = Self.padding
        let textWidth = Self.maxWidth - pad * 2

        // 按固定宽度排版，测得完整文本高度
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager!.usedRect(for: textView.textContainer!)

        let fullTextHeight = max(ceil(used.height) + 2, 40)
        let visibleHeight = min(fullTextHeight, Self.maxContentHeight)

        // textView = 完整内容尺寸（超出可视区由 scrollView 滚动）
        textView.frame = NSRect(x: 0, y: 0, width: textWidth, height: fullTextHeight)

        // scrollView 占据可视区域
        let toolbarHeight: CGFloat = 24
        let toolbarSpacing: CGFloat = 8
        toolbar.frame = NSRect(x: pad, y: pad, width: textWidth, height: toolbarHeight)
        let scrollY = pad + toolbarHeight + toolbarSpacing
        scrollView.frame = NSRect(x: pad, y: scrollY, width: textWidth, height: visibleHeight)

        // 顶部握把：位于正文之上，拖动即移动窗口（内容区不抢鼠标，文本仍可选中）
        let handleY = scrollY + visibleHeight + Self.handleSpacing
        dragHandle.frame = NSRect(x: pad, y: handleY, width: textWidth, height: Self.handleHeight)

        let width = textWidth + pad * 2
        let height = visibleHeight + pad * 2 + toolbarHeight + toolbarSpacing + Self.handleHeight + Self.handleSpacing

        // 定位：未拖动时贴选区锚点；拖动过之后沿用用户给的左上角，只向下生长。
        // 拖动过以后按「窗口实际所在屏」clamp（多显示器下不会被打回锚点所在的屏）。
        let referenceScreen = (pinnedTopLeft != nil ? panel.screen : nil) ?? Self.screen(for: mouse)
        let visible = referenceScreen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = PopoverPlacement.origin(
            size: NSSize(width: width, height: height),
            anchor: mouse,
            pinnedTopLeft: pinnedTopLeft,
            screen: visible
        )
        setPanelFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)))
        // 不把 clamp 结果写回 pinnedTopLeft：用户的左上角是「意图」，越界由每帧 clamp 兜住。
        // 写回会让贴底/贴边时每增长一行就把顶边往上顶一段（弹窗顺着流式内容一路向上爬）。
    }

    /// 按内容重排窗口：标记为程序化移动，避免 didMove 把这次布局当成用户拖动
    private func setPanelFrame(_ frame: NSRect) {
        isProgrammaticMove = true
        panel.setFrame(frame, display: true)
        isProgrammaticMove = false
    }

    /// 握把拖动：自己跑拖拽循环（无边框 + nonactivating 面板下不依赖窗口能否成为 key），
    /// 每 0.25s 醒一次，鼠标已松开却没收到 up 事件时也能安全退出，不会卡死主线程。
    private func dragPanel(with event: NSEvent) {
        let startMouse = NSEvent.mouseLocation
        let startOrigin = panel.frame.origin
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            let next = NSApp.nextEvent(
                matching: mask, until: Date().addingTimeInterval(0.25),
                inMode: .eventTracking, dequeue: true
            )
            guard let next else {
                // 超时：没有新事件时确认鼠标是否已经松开（拖到别的应用上松开就收不到 up）
                if NSEvent.pressedMouseButtons == 0 { break }
                continue
            }
            if next.type == .leftMouseUp { break }
            let current = PopoverDrag.origin(
                startOrigin: startOrigin, startMouse: startMouse, currentMouse: NSEvent.mouseLocation
            )
            isProgrammaticMove = true
            panel.setFrameOrigin(current)
            isProgrammaticMove = false
        }
        // 只是点了一下握把（没拖动）就保持原来的贴锚点行为，别顺手把它变成「手动位置」
        guard panel.frame.origin != startOrigin else { return }
        pinnedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// 窗口被移动（用户拖动）：记下左上角，后续内容增长只向下长，不再被锚点拽回去
    @objc private func panelDidMove(_ notification: Notification) {
        guard !isProgrammaticMove else { return }
        pinnedTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    /// 关闭弹窗：清理监视器与倒计时并通知 onClose（幂等）
    func close() {
        removeDismissMonitor()
        removeKeyMonitor()
        autoClose.invalidate()
        result = nil
        retry = nil
        toggleFavorite = nil
        pinnedTopLeft = nil
        speech.stopSpeaking(at: .immediate)
        panel.orderOut(nil)
        onClose?()
    }

    private func configureToolbar() {
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.detachesHiddenViews = true
        let spacer = NonDraggableSpacer()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions: [(NSButton, Selector)] = [
            (copyButton, #selector(copyResult)), (speakButton, #selector(speakTerm)),
            (pinButton, #selector(togglePin)), (favoriteButton, #selector(favoriteResult)),
            (retryButton, #selector(retryQuery)),
            (closeButton, #selector(closeFromButton))
        ]
        for (button, action) in actions {
            if button === closeButton { toolbar.addArrangedSubview(spacer) }
            button.target = self
            button.action = action
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            toolbar.addArrangedSubview(button)
        }
    }

    @objc private func copyResult() {
        guard let result else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(result.content, forType: .string) { copyButton.title = "已复制" }
    }

    @objc private func speakTerm() {
        guard let result else { return }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: result.term)
        if let language = NLLanguageRecognizer.dominantLanguage(for: result.term) {
            utterance.voice = AVSpeechSynthesisVoice(language: language.rawValue)
        }
        speech.speak(utterance)
    }

    @objc private func togglePin() {
        autoClose.setPinned(!autoClose.isPinned)
        pinButton.title = autoClose.isPinned ? "取消钉住" : "钉住"
    }

    @objc private func retryQuery() { retry?() }
    @objc private func closeFromButton() { close() }

    @objc private func favoriteResult() {
        guard let favorite = toggleFavorite?() else {
            favoriteButton.isHidden = true
            return
        }
        favoriteButton.title = favorite ? "取消收藏" : "收藏"
    }

    /// Esc 关闭。两条路径缺一不可：
    /// - 本地监视器：设置窗口等本进程窗口获得焦点时，能在事件分发前消费掉 Esc；
    /// - 全局监视器：弹窗是 nonactivating 的、原应用保持焦点，此时键事件根本不进本进程，
    ///   只有全局监视器能收到。全局监视器无法消费事件（macOS 不提供），
    ///   因此原应用仍会收到这次 Esc —— README 已按此说明。
    private func addKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event } // 53 = Esc
            self.close()
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            self?.close()
        }
    }

    /// 移除 Esc 监视器（本地 + 全局）
    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
    }

    /// 悬停期间冻结自动关闭倒计时，移开后重新计时（状态由 AutoCloseScheduler 保存）
    private func hoverChanged(_ hovering: Bool) {
        autoClose.hoverChanged(hovering)
    }

    /// 点所在屏幕（多点时按坐标找所在屏）
    private static func screen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// 点击弹窗外任意位置即关闭（全局监视；点击弹窗自身不触发）
    private func addDismissMonitor() {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, !self.autoClose.isPinned else { return }
            let loc = NSEvent.mouseLocation
            let hit = NSWindow.windowNumber(at: loc, belowWindowWithWindowNumber: 0)
            if hit != self.panel.windowNumber {
                self.close()
            }
        }
    }

    /// 移除点击外部监视器
    private func removeDismissMonitor() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
    }
}

/// 工具栏容器：不参与窗口背景拖动，避免点按钮间隙时误拖整个弹窗
private final class NonDraggableStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 工具栏里撑开按钮组的弹性空白：同样不参与窗口拖动
private final class NonDraggableSpacer: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 能感知鼠标进出的容器视图（用于悬停暂停倒计时，同时承担背景拖动）
private final class HoverDetectingView: NSView {
    /// 进/出回调（true = 进入）
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    /// 空白处按住即可拖动窗口（正文由 NSTextView 自己处理，保留文本选择）
    override var mouseDownCanMoveWindow: Bool { true }

    /// bounds 变化时重建跟踪区，保证悬停检测覆盖最新可视范围
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

/// 顶部握把：唯一的、看得见的移动入口。按下后由 ResultPopover 跑拖拽循环移动面板；
/// 自绘三条短横线（随亮暗外观自动取色），不参与正文布局。
private final class PopoverDragHandle: NSView {
    /// 按下时请求拖动（ResultPopover 负责跟随鼠标移动窗口并记录新位置）
    var onDragRequest: ((NSEvent) -> Void)?

    /// 自己接管按下事件：不交给 AppKit 的 background 拖动，拖动过程与位置记账都走 dragPanel
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        onDragRequest?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 22
        let barHeight: CGFloat = 1.5
        let gap: CGFloat = 2.5
        let total = barHeight * 3 + gap * 2
        var y = bounds.midY - total / 2
        NSColor.tertiaryLabelColor.setFill()
        for _ in 0..<3 {
            let rect = NSRect(x: bounds.midX - barWidth / 2, y: y, width: barWidth, height: barHeight)
            NSBezierPath(roundedRect: rect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            y += barHeight + gap
        }
    }
}

/// 弹窗定位算法（纯函数，单测覆盖）：默认贴鼠标锚点，用户拖动过之后固定左上角，
/// 两种情况最后都整体 clamp 进屏幕可视区，保证不会只露出一角。
/// 拖动位移计算（纯函数，单测覆盖）：按下时的窗口原点 + 鼠标位移（屏幕坐标，天然支持多显示器）
enum PopoverDrag {
    static func origin(startOrigin: NSPoint, startMouse: NSPoint, currentMouse: NSPoint) -> NSPoint {
        NSPoint(
            x: startOrigin.x + currentMouse.x - startMouse.x,
            y: startOrigin.y + currentMouse.y - startMouse.y
        )
    }
}

enum PopoverPlacement {
    /// 锚点与窗口的间距（默认放在鼠标右下方，放不下翻到上方）
    static let anchorGap: CGFloat = 16
    /// 窗口与屏幕可视区边缘的最小留白
    static let screenInset: CGFloat = 8

    static func origin(
        size: NSSize, anchor: NSPoint, pinnedTopLeft: NSPoint?, screen: NSRect
    ) -> NSPoint {
        var x: CGFloat
        var y: CGFloat
        if let pinnedTopLeft {
            // 用户拖动过：左上角不动，高度变化时向下生长（流式内容变长不会盖住选区）
            x = pinnedTopLeft.x
            y = pinnedTopLeft.y - size.height
        } else {
            x = anchor.x + anchorGap
            y = anchor.y - size.height - anchorGap
            if y < screen.minY { y = anchor.y + anchorGap }
        }
        // 右/上越界时回退留白；左/下越界时贴边（窗口比屏幕还大时优先保证左上角可见）
        x = min(x, screen.maxX - size.width - screenInset)
        y = min(y, screen.maxY - size.height - screenInset)
        x = max(x, screen.minX + screenInset)
        y = max(y, screen.minY + screenInset)
        return NSPoint(x: x, y: y)
    }
}
