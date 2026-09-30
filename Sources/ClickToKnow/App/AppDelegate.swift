import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var selectionMonitor: SelectionMonitor?
    private var popover: ResultPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController()
        popover = ResultPopover()
        setupSelectionMonitor()
        requestAccessibilityIfNeeded()
        NSLog("[ClickToKnow] LLM 配置：%@", AppConfig.shared.hasLLMConfig ? "已就绪" : "未配置（回落到系统词典）")
    }

    private func setupSelectionMonitor() {
        selectionMonitor = SelectionMonitor { [weak self] text, location in
            self?.handleSelectedText(text, at: location)
        }
        selectionMonitor?.start()
    }

    private func handleSelectedText(_ text: String, at location: NSPoint) {
        // 每次按最新配置装配，改设置后立即生效
        let provider = ProviderFactory.make()
        Task {
            do {
                let result = try await provider.interpret(text)
                self.show(result, at: location)
            } catch {
                NSLog("[ClickToKnow] 释义失败：%@", String(describing: error))
            }
        }
    }

    private func show(_ result: Interpretation, at location: NSPoint) {
        let attributed = MarkdownRenderer.render(result.content)
        popover?.show(attributed, at: location)
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("[ClickToKnow] 需要辅助功能权限：系统设置 → 隐私与安全 → 辅助功能，勾选本程序后重启")
        }
    }
}