import AppKit

/// 系统设置面板直达入口（菜单栏与状态页共用，避免两处硬编码 URL）。
enum SystemSettingsOpener {
    /// 隐私与安全 → 辅助功能（模拟 ⌘C 抓词的授权面板）
    static func openAccessibility() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
