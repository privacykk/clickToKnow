import AppKit
import SwiftUI

/// 历史记录窗口：AppKit 壳 + SwiftUI 内容，与设置窗口同模式（懒创建复用）。
@MainActor
final class HistoryWindowController: NSWindowController {
    private static let contentSize = NSSize(width: 720, height: 480)

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "历史记录"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let hosting = NSHostingController(rootView: HistoryView())
        // 先给宿主视图目标尺寸再挂载（同 SettingsWindowController 的窗口塌陷教训）
        hosting.view.frame = NSRect(origin: .zero, size: Self.contentSize)
        window.contentViewController = hosting
        window.setContentSize(Self.contentSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}
