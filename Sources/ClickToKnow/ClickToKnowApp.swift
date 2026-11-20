import AppKit

/// 程序入口：启动即打开「设置与状态中心」窗口，Dock 有图标；
/// 菜单栏图标保留作快捷入口，划词热键流程不变。
@main
struct ClickToKnowApp {
    @MainActor
    static func main() {
        EnvLoader.load() // 先加载 .env，让密钥可用
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // regular 策略：显示 Dock 图标、支持 reopen（点击 Dock 重新唤起窗口）
        app.setActivationPolicy(.regular)
        // run() 阻塞直至 terminate，局部 delegate 在整个运行期存活
        app.run()
    }
}
