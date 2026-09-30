import AppKit

/// 就地悬浮展示释义的无边框面板：不抢焦点、浮于其它窗口之上、点击外部/超时自动关闭。
@MainActor
final class ResultPopover {
    private let panel: NSPanel
    private let container: NSView
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var dismissMonitor: Any?
    private var autoCloseItem: DispatchWorkItem?

    private static let maxWidth: CGFloat = 420
    private static let maxContentHeight: CGFloat = 340
    private static let padding: CGFloat = 14

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.maxWidth, height: 120),
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
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView

        container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        // 关键：把 scrollView 放进容器视图树，否则不显示
        container.addSubview(scrollView)
        panel.contentView = container
    }

    func show(_ attributed: NSAttributedString, at mouse: NSPoint) {
        let pad = Self.padding
        let textWidth = Self.maxWidth - pad * 2

        // 先按最大宽度排版，得到文本实际占用的宽高
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)

        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero

        // 内容宽高：宽按实际（短文本不撑满），高为完整文本高度 + clamp 到一个上限
        let contentWidth = min(max(used.width + 4, 160), textWidth)
        let fullTextHeight = max(used.height + 4, 24)
        let visibleHeight = min(fullTextHeight, Self.maxContentHeight)

        let width = contentWidth + pad * 2
        let height = visibleHeight + pad * 2

        // textView 高度设为完整文本高度（超过可视区由 scrollView 滚动）
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: fullTextHeight)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)

        // scrollView 占据容器可视区域
        scrollView.frame = NSRect(x: pad, y: pad, width: width - pad * 2, height: height - pad * 2)

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
        scheduleAutoClose()
        panel.orderFront(nil)
    }

    func close() {
        removeDismissMonitor()
        autoCloseItem?.cancel()
        autoCloseItem = nil
        panel.orderOut(nil)
    }

    private static func screen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private func scheduleAutoClose() {
        autoCloseItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.close()
        }
        autoCloseItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

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

    private func removeDismissMonitor() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
    }
}