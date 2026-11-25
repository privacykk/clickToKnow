import AppKit
import AVFoundation
import NaturalLanguage

/// 就地悬浮展示释义的无边框面板：不抢焦点、浮于其它窗口之上、点击外部/超时自动关闭，
/// 鼠标悬停期间暂停倒计时（避免长内容读到一半被打断）。
@MainActor
final class ResultPopover: NSObject {
    /// 无边框不抢焦点的浮动面板
    private let panel: NSPanel
    /// 圆角容器（同时承担悬停检测）
    private let container: HoverDetectingView
    private let scrollView: NSScrollView
    /// 释义内容承载（Markdown 渲染结果直接设置）
    private let textView: NSTextView
    private let toolbar = NSStackView()
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

    /// 弹窗关闭时回调（点击外部 / 超时 / Esc）：AppDelegate 借此取消仍在进行的 LLM 请求，避免白烧 token
    var onClose: (() -> Void)?

    // 尺寸约束：内容超出最大高度转为滚动
    private static let maxWidth: CGFloat = 560
    private static let maxContentHeight: CGFloat = 500
    private static let padding: CGFloat = 16

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
        panel.contentView = container
        autoClose.onFire = { [weak self] in
            self?.close()
        }
    }

    /// 跟随系统亮暗外观：cgColor 是快照，弹窗生命周期短（≤25s），每次展示时刷新一次即可
    private func applyAppearance() {
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// 首次展示（或切换到一条新内容）：定尺寸定位 → 装监视器 → 排倒计时 → 上屏。
    /// 流式增量请走 `updateContent`，否则每帧重装监视器与重排倒计时会把悬停暂停覆盖掉。
    func show(
        _ attributed: NSAttributedString, at mouse: NSPoint, autoCloseAfter: TimeInterval = 15,
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
        layout(attributed, at: mouse)
        addDismissMonitor()
        addKeyMonitor()
        autoClose.restart(duration: autoCloseAfter)
        panel.orderFront(nil)
        autoClose.hoverChanged(panel.frame.contains(NSEvent.mouseLocation))
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
        scrollView.frame = NSRect(x: pad, y: pad + toolbarHeight + toolbarSpacing, width: textWidth, height: visibleHeight)

        let width = textWidth + pad * 2
        let height = visibleHeight + pad * 2 + toolbarHeight + toolbarSpacing

        // 定位到鼠标附近并 clamp 进屏幕
        let visible = Self.screen(for: mouse)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var x = mouse.x + 16
        var y = mouse.y - height - 16
        if y < visible.minY { y = mouse.y + 16 }
        if x + width > visible.maxX { x = visible.maxX - width - 8 }
        if x < visible.minX { x = visible.minX + 8 }
        if y + height > visible.maxY { y = visible.maxY - height - 8 }

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    /// 关闭弹窗：清理监视器与倒计时并通知 onClose（幂等）
    func close() {
        removeDismissMonitor()
        removeKeyMonitor()
        autoClose.invalidate()
        result = nil
        retry = nil
        toggleFavorite = nil
        speech.stopSpeaking(at: .immediate)
        panel.orderOut(nil)
        onClose?()
    }

    private func configureToolbar() {
        toolbar.orientation = .horizontal
        toolbar.spacing = 8
        toolbar.detachesHiddenViews = true
        let spacer = NSView()
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

/// 能感知鼠标进出的容器视图（用于悬停暂停倒计时）
private final class HoverDetectingView: NSView {
    /// 进/出回调（true = 进入）
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

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
