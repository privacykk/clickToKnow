import AppKit
import SwiftUI

/// 状态总览：一屏看清「能不能用、差在哪一步」——顶部一句话结论 + 可点击的去处，
/// 下面按权限 / 快捷键 / 释义 / 运行时分组展示明细。
/// 可见期间由 AppStatusModel 以 1s 轮询（onAppear 启动、onDisappear 停止，避免常驻开销）；
/// 配置变更还会通过通知立即刷新，因此从「大模型」页保存回来不会看到过期状态。
@MainActor
struct StatusTabView: View {
    @EnvironmentObject private var statusModel: AppStatusModel
    /// 根视图页签选择：总览里的「去配置 / 去修改」直接跳转对应页
    @Binding var selection: SettingsTab

    var body: some View {
        Form {
            Section {
                overviewRow
            }

            Section("权限") {
                LabeledContent("辅助功能权限") {
                    HStack(spacing: 10) {
                        StatusBadge(
                            level: statusModel.accessibilityGranted ? .ok : .bad,
                            text: statusModel.accessibilityGranted ? "已授权" : "未授权"
                        )
                        if !statusModel.accessibilityGranted {
                            Button("打开系统设置") { SystemSettingsOpener.openAccessibility() }
                        }
                        Button("刷新") { statusModel.refresh() }
                    }
                }
                Text("抓取选词依赖模拟 ⌘C；授权后若划词仍无效，请重启 ClickToKnow（裸可执行文件重新编译会使授权失效）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("快捷键") {
                LabeledContent("全局热键") {
                    HStack(spacing: 10) {
                        Text(statusModel.hotKeyBinding.displayString)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        StatusBadge(level: hotKeyBadgeLevel, text: hotKeyBadgeText)
                        Button("修改") { selection = .hotKey }
                    }
                }
            }

            Section("释义") {
                LabeledContent("当前来源") {
                    HStack(spacing: 10) {
                        StatusBadge(level: llmBadgeLevel, text: llmBadgeText)
                        if statusModel.llmStatus != .ready {
                            Button(statusModel.profileCount == 0 ? "去配置" : "去补全") { selection = .llm }
                        }
                    }
                }
                if statusModel.llmStatus != .notConfigured {
                    LabeledContent("模型") {
                        HStack(spacing: 6) {
                            Text(statusModel.activeModel)
                                .lineLimit(1)
                            if !statusModel.activeProtocolName.isEmpty {
                                Text(statusModel.activeProtocolName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    LabeledContent("端点") {
                        Text(statusModel.activeBaseURL)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(statusModel.activeBaseURL)
                    }
                }
                LabeledContent("API Key") {
                    Text(keyText)
                        .foregroundStyle(
                            statusModel.profileCount > 0 && statusModel.maskedKey == nil && requiresKey
                                ? Color.orange : Color.primary
                        )
                }
            }

            Section("运行时") {
                LabeledContent("版本") {
                    Text(AppStatusModel.version)
                }
                LabeledContent("可执行路径") {
                    Text(statusModel.executablePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(statusModel.executablePath)
                }
                LabeledContent("诊断") {
                    Button("导出诊断信息") { exportDiagnostics() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { statusModel.startMonitoring() }
        .onDisappear { statusModel.stopMonitoring() }
    }

    // MARK: - 顶部结论

    /// 一句话结论：先处理最影响可用性的那一项，并给出直达按钮
    @ViewBuilder
    private var overviewRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: summaryIcon)
                .font(.system(size: 26))
                .foregroundStyle(summaryColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(summaryTitle)
                    .font(.headline)
                Text(summaryDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action = summaryAction {
                Button(action.title) { perform(action.action) }
            }
        }
        .padding(.vertical, 4)
    }

    /// 顶部结论对应的动作：页签跳转，或直达系统设置的权限面板
    private enum SummaryAction {
        case tab(SettingsTab)
        case openAccessibility
    }

    /// 结论优先级：权限（完全不可用）> 大模型（缺配置/缺密钥）> 热键注册 > 暂停
    private var summaryAction: (title: String, action: SummaryAction)? {
        if !statusModel.accessibilityGranted {
            return ("打开系统设置", .openAccessibility)
        }
        switch statusModel.llmStatus {
        case .notConfigured:
            return ("去配置大模型", .tab(.llm))
        case .missingKey:
            return ("去填写密钥", .tab(.llm))
        case .ready:
            if statusModel.hotKeyPaused {
                return nil
            }
            return statusModel.hotKeyRegistered ? nil : ("去修改快捷键", .tab(.hotKey))
        }
    }

    private var summaryIcon: String {
        if !statusModel.accessibilityGranted { return "exclamationmark.triangle.fill" }
        if statusModel.llmStatus != .ready { return "exclamationmark.triangle.fill" }
        if statusModel.hotKeyPaused { return "pause.circle.fill" }
        if !statusModel.hotKeyRegistered { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    private var summaryColor: Color {
        if !statusModel.accessibilityGranted || statusModel.llmStatus != .ready { return .orange }
        if statusModel.hotKeyPaused || !statusModel.hotKeyRegistered { return .orange }
        return .green
    }

    private var summaryTitle: String {
        if !statusModel.accessibilityGranted { return "还不能用：缺少辅助功能权限" }
        switch statusModel.llmStatus {
        case .notConfigured:
            return statusModel.profileCount == 0 ? "尚未配置大模型" : "当前配置不完整"
        case .missingKey:
            return "大模型已保存，但还缺 API Key"
        case .ready:
            if statusModel.hotKeyPaused { return "取词已暂停" }
            if !statusModel.hotKeyRegistered { return "快捷键未注册" }
            return "一切就绪"
        }
    }

    private var summaryDetail: String {
        if !statusModel.accessibilityGranted {
            return "划词释义依赖模拟 ⌘C，先在系统设置中授权后重启应用。"
        }
        switch statusModel.llmStatus {
        case .notConfigured:
            return statusModel.profileCount == 0
                ? "现在由 macOS 系统词典兜底；添加一个 API 配置即可使用大模型释义。"
                : "已保存的配置缺少端点或模型，请补全后再保存。"
        case .missingKey:
            return "「\(statusModel.activeModel)」划词时仍会回落系统词典，填入密钥后立即生效。"
        case .ready:
            if statusModel.hotKeyPaused {
                return "可在菜单栏的「暂停取词」处恢复。"
            }
            if !statusModel.hotKeyRegistered {
                return "当前绑定被占用或注册失败，换一个组合键即可。"
            }
            return "选中文字后按 \(statusModel.hotKeyBinding.displayString) 获取释义。"
        }
    }

    private func perform(_ action: SummaryAction) {
        switch action {
        case .tab(let tab):
            selection = tab
        case .openAccessibility:
            SystemSettingsOpener.openAccessibility()
        }
    }

    // MARK: - 释义状态

    /// 生效配置是否要求密钥（Ollama 等本地预设可选）
    private var requiresKey: Bool {
        !(ProviderPresets.matching(baseURL: statusModel.activeBaseURL)?.apiKeyOptional ?? false)
    }

    /// 未配置 / 缺密钥都算「未就绪」，用橙色而非红色：系统词典兜底本身仍可用
    private var llmBadgeLevel: StatusBadge.Level {
        statusModel.llmStatus == .ready ? .ok : .warn
    }

    private var llmBadgeText: String {
        switch statusModel.llmStatus {
        case .ready: return statusModel.activeModel
        case .missingKey: return "缺少密钥（回落系统词典）"
        case .notConfigured: return "系统词典（未配置 LLM）"
        }
    }

    /// 暂停时热键未注册是预期状态，展示「已暂停」而非误导性的「注册失败」
    private var hotKeyBadgeLevel: StatusBadge.Level {
        if statusModel.hotKeyPaused { return .warn }
        return statusModel.hotKeyRegistered ? .ok : .bad
    }

    /// 热键徽标文案（与等级联动）
    private var hotKeyBadgeText: String {
        if statusModel.hotKeyPaused { return "已暂停（菜单栏可恢复）" }
        return statusModel.hotKeyRegistered ? "已注册" : "注册失败"
    }

    /// 导出诊断报告（脱敏后的状态汇总）到用户选择的文本文件
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clicktoknow-diagnostics.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? statusModel.diagnosticReport().write(to: url, atomically: true, encoding: .utf8)
    }

    /// 掩码密钥 + 生效来源（环境来源合并展示「环境变量 / .env」，二者运行时不可分辨）
    private var keyText: String {
        guard let masked = statusModel.maskedKey else {
            if statusModel.profileCount == 0 { return "未配置" }
            return requiresKey ? "未配置（该供应商必需）" : "未配置（该供应商可留空）"
        }
        switch statusModel.keySource {
        case .environment: return "\(masked) · 来自环境变量 / .env"
        case .keychain: return "\(masked) · 来自钥匙串"
        case .legacyUserDefaults: return "\(masked) · 来自本地存储（钥匙串不可用，已回退）"
        case .none: return masked
        }
    }
}
