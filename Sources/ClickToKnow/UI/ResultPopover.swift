import AppKit

/// 就地悬浮展示释义的无边框面板：不抢焦点、浮于其它窗口之上、点击外部/超时自动关闭，
/// 鼠标悬停期间暂停倒计时（避免长内容读到一半被打断）。
@MainActor
final class ResultPopover {
    /// 无边框不抢焦点的浮动面板
    private let panel: NSPanel
    /// 圆角容器（同时承担悬停检测）
    private let container: HoverDetectingView
    private let scrollView: NSScrollView
    /// 释义内容承载（Markdown 渲染结果直接设置）
    private let textView: NSTextView
    /// 点击外部关闭的全局监视器
    private var dismissMonitor: Any?
    /// Esc 关闭的本地监视器
    private var keyMonitor: Any?
    /// 自动关闭任务（悬停时可取消重排）
    private var autoCloseItem: DispatchWorkItem?

    /// 当前展示使用的自动关闭时限（悬停暂停倒计时时要用）
    private var autoCloseDuration: TimeInterval = 15

    /// 弹窗关闭时回调（点击外部 / 超时 / Esc）：AppDelegate 借此取消仍在进行的 LLM 请求，避免白烧 token
    var onClose: (() -> Void)?

    // 尺寸约束：内容超出最大高度转为滚动
    private static let maxWidth: CGFloat = 560
    private static let maxContentHeight: CGFloat = 500
    private static let padding: CGFloat = 16

    /// 组装面板、滚动视图、文本视图与悬停容器
    init() {
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
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 0.5
        applyAppearance()
        container.onHover = { [weak self] hovering in
            self?.hoverChanged(hovering)
        }
        container.addSubview(scrollView)
        panel.contentView = container
    }

    /// 跟随系统亮暗外观：cgColor 是快照，弹窗生命周期短（≤25s），每次展示时刷新一次即可
    private func applyAppearance() {
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// 展示弹窗：按内容测高定尺寸，锚点贴调用方给定的屏幕位置并 clamp 进可视区。
    /// 每次展示重装监视器与倒计时（loading 增量复用同一弹窗刷新内容）。
    func show(_ attributed: NSAttributedString, at mouse: NSPoint, autoCloseAfter: TimeInterval = 15) {
        autoCloseDuration = autoCloseAfter
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
        scrollView.frame = NSRect(x: pad, y: pad, width: textWidth, height: visibleHeight)

        let width = textWidth + pad * 2
        let height = visibleHeight + pad * 2

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
        addDismissMonitor()
        addKeyMonitor()
        scheduleAutoClose()
        panel.orderFront(nil)
    }

    /// 关闭弹窗：清理监视器与倒计时并通知 onClose（幂等）
    func close() {
        removeDismissMonitor()
        removeKeyMonitor()
        autoCloseItem?.cancel()
        autoCloseItem = nil
        panel.orderOut(nil)
        onClose?()
    }

    /// Esc 关闭：panel 是 nonactivating 不会成为 key window，键事件仍发往原焦点应用，
    /// 因此用本地监视器在事件分发前拦截；消费掉 Esc（return nil），避免前景应用二次响应
    private func addKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event } // 53 = Esc
            self.close()
            return nil
        }
    }

    /// 移除 Esc 监视器
    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// 悬停期间冻结自动关闭倒计时，移开后重新计时
    private func hoverChanged(_ hovering: Bool) {
        if hovering {
            autoCloseItem?.cancel()
            autoCloseItem = nil
        } else {
            scheduleAutoClose()
        }
    }

    /// 点所在屏幕（多点时按坐标找所在屏）
    private static func screen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// 重排自动关闭倒计时（展示与悬停移开时调用）
    private func scheduleAutoClose() {
        autoCloseItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.close()
        }
        autoCloseItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autoCloseDuration, execute: item)
    }

    /// 点击弹窗外任意位置即关闭（全局监视；点击弹窗自身不触发）
    private func addDismissMonitor() {
        removeDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
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
