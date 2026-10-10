import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var selectionMonitor: SelectionMonitor?
    private var popover: ResultPopover?

    /// 自增请求序号：LLM 响应耗时不定，若两次查询的返回顺序颠倒，
    /// 只展示最新一次的结果，丢弃过期响应。
    private var requestCounter = 0

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
        requestCounter += 1
        let requestID = requestCounter

        // 立即反馈：否则 deepseek-flash 带推理要数秒，期间界面像卡死。
        // 展示时限 25s > 请求超时 20s，保证超时错误能顶替 loading 出现
        popover?.show(MarkdownRenderer.render("查询中…"), at: location, autoCloseAfter: 25)

        // 每次按最新配置装配，改设置后立即生效
        let provider = ProviderFactory.make()
        Task {
            do {
                let result = try await provider.interpret(text)
                guard requestID == self.requestCounter else { return } // 已被更新的查询取代
                self.show(result, at: location)
            } catch {
                guard requestID == self.requestCounter else { return }
                let message = (error as? InterpretationError)?.userMessage
                    ?? "查询失败：\(error.localizedDescription)"
                NSLog("[ClickToKnow] 释义失败：%@", message)
                self.showFailure(message, for: text, at: location)
            }
        }
    }

    private func show(_ result: Interpretation, at location: NSPoint) {
        popover?.show(MarkdownRenderer.render(result.content), at: location)
    }

    private func showFailure(_ message: String, for text: String, at location: NSPoint) {
        let hint = """
        **未能查询：\(text)**

        \(message)

        ▸ 可在菜单栏「设置…」检查 Base URL / Model / 密钥
        """
        popover?.show(MarkdownRenderer.render(hint), at: location)
    }

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSLog("[ClickToKnow] 需要辅助功能权限：系统设置 → 隐私与安全 → 辅助功能，勾选本程序后重启")
        }
    }
}
