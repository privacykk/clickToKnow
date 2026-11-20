import AppKit
import ApplicationServices
import Combine
import ServiceManagement

/// 运行时状态聚合：SwiftUI 设置页与菜单栏菜单的共同数据源。
/// 只负责「读状态 + 轮询生命周期」，不修改任何配置；轮询 Timer 仅在监控开启期间存在。
@MainActor
final class AppStatusModel: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var hotKeyBinding = CarbonKeyTranslator.defaultBinding
    @Published private(set) var hotKeyRegistered = false
    /// 取词已暂停（菜单栏开关）：此时 hotKeyRegistered 必为 false，展示层应优先显示「已暂停」而非「注册失败」
    @Published private(set) var hotKeyPaused = false
    @Published private(set) var llmReady = false
    /// 当前生效的模型名；空串 = 未配置 LLM，走系统词典兜底
    @Published private(set) var activeModel = ""
    @Published private(set) var keySource: AppConfig.APIKeySource = .none
    @Published private(set) var maskedKey: String?

    /// 读取热键真实注册状态；AppDelegate 装配完成后注入
    weak var selectionMonitor: SelectionMonitor?

    /// 打包成 .app 时读 Info.plist 的 CFBundleShortVersionString（由 Scripts/package.sh 注入）；
    /// 裸可执行（swift run）没有 bundle 信息，回退 dev 标识
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.2.1-dev"
    }

    /// 可执行文件绝对路径（解析符号链接），供排查裸可执行文件的辅助功能授权问题：
    /// 权限按进程路径记录，swift run 重新编译后路径虽同但二进制已变，授权可能失效
    let executablePath: String = AppStatusModel.resolveExecutablePath()

    private var pollTimer: Timer?

    /// 开启 1s 轮询（幂等）。设置窗口成为 key / 状态 Tab 出现时调用。
    func startMonitoring() {
        refresh()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 诊断报告：状态汇总文本，供「导出诊断信息」按钮落盘。
    /// 密钥只含掩码与来源，绝不包含明文；日志可用 `log show --predicate 'subsystem == "ClickToKnow"'` 单独收集。
    func diagnosticReport() -> String {
        """
        ClickToKnow 诊断报告
        生成时间：\(Date().formatted(date: .complete, time: .standard))
        版本：\(Self.version)
        可执行路径：\(executablePath)
        辅助功能权限：\(accessibilityGranted ? "已授权" : "未授权")
        快捷键：\(hotKeyBinding.displayString)（\(hotKeyPaused ? "已暂停" : (hotKeyRegistered ? "已注册" : "注册失败"))）
        释义来源：\(llmReady ? "大模型 · \(activeModel)" : "系统词典（未配置 LLM）")
        API Key：\(maskedKey ?? "未配置")（来源：\(keySource.rawValue)）
        开机自启：\(SMAppService.mainApp.status == .enabled ? "已开启" : "未开启")
        历史记录：\(HistoryStore.shared.entries.count) 条
        取词路径：AX 直读优先，⌘C 兜底
        """
    }

    /// 幂等全量拉取：轮询、菜单展开、Tab 切入、保存配置后都会调用。
    /// 钥匙串读取经 KeychainSecretStore 内存缓存，秒级频率不会反复触发系统询问。
    func refresh() {
        accessibilityGranted = AXIsProcessTrusted()

        let config = AppConfig.shared
        if let monitor = selectionMonitor {
            hotKeyBinding = monitor.currentBinding
            hotKeyRegistered = monitor.isHotKeyRegistered
            hotKeyPaused = monitor.isPaused
        } else {
            hotKeyBinding = config.hotKeyBinding
            hotKeyRegistered = false
            hotKeyPaused = false
        }

        llmReady = config.hasLLMConfig
        activeModel = llmReady ? config.model : ""
        keySource = config.apiKeySource
        maskedKey = config.maskedAPIKey
    }

    private static func resolveExecutablePath() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = UInt32(buffer.count)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return CommandLine.arguments.first ?? "(未知)"
        }
        // swift run 的产物常是指向 .build/debug/ 的符号链接，解析到真实路径
        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath().path
    }
}
