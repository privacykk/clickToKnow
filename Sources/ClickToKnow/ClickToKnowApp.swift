import AppKit

/// 程序入口：一个纯菜单栏（accessory）的 App，不显示 Dock 图标。
@main
struct ClickToKnowApp {
    @MainActor
    static func main() {
        EnvLoader.load() // 先加载 .env，让密钥可用
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // run() 阻塞直至 terminate，局部 delegate 在整个运行期存活
        app.run()
    }
}