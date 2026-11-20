import AppKit
import SwiftUI

/// 设置与状态中心窗口：AppKit 壳（NSWindow）+ SwiftUI 内容（三 Tab）。
/// 窗口懒创建复用；状态轮询只由「状态总览」Tab 的可见性驱动（onAppear/onDisappear），
/// 窗口级只兜底关闭时停止，避免窗口停在其它 Tab 时仍以 1Hz 轮询。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let statusModel: AppStatusModel

    /// 固定内容尺寸：窗口与 SwiftUI 宿主视图共用同一来源，避免两处硬编码漂移。
    /// 高度取 560 而非设计稿的 520：macOS 26+ 的 TabView 会把页签条嵌在内容区顶部（约占 30pt），
    /// 520 会裁掉「状态总览」最后一行（可执行路径），560 可一屏放完。
    private static let contentSize = NSSize(width: 560, height: 560)

    init(statusModel: AppStatusModel) {
        self.statusModel = statusModel
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClickToKnow 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let hosting = NSHostingController(
            rootView: SettingsRootView()
                .environmentObject(statusModel)
        )
        // 教训：NSWindow.contentViewController 的 setter 会按 hosting view **当时的 frame** 重设窗口大小。
        // NSHostingController 尚未布局时 frame 只有 60×32，直接把窗口塌成一条标题栏（三 Tab 被裁掉）。
        // 因此先给宿主视图目标尺寸再挂载，挂载后重申一次内容尺寸并居中，保证窗口不会塌陷。
        hosting.view.frame = NSRect(origin: .zero, size: Self.contentSize)
        window.contentViewController = hosting
        window.setContentSize(Self.contentSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// 窗口复用打开时先全量刷新一次，避免展示上一次的过期状态
    override func showWindow(_ sender: Any?) {
        statusModel.refresh()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        statusModel.stopMonitoring()
    }
}
