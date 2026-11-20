import AppKit
import SwiftUI

/// 状态总览：权限 / 快捷键 / 释义 / 运行时四组信息。
/// 可见期间由 AppStatusModel 以 1s 轮询（onAppear 启动、onDisappear 停止，避免常驻开销）。
@MainActor
struct StatusTabView: View {
    @EnvironmentObject private var statusModel: AppStatusModel

    var body: some View {
        Form {
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
                Text("抓取选词依赖模拟 ⌘C，必须获得此权限；授权后若划词仍无效，请重启 ClickToKnow（裸可执行文件重新编译会使授权失效）。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("快捷键") {
                LabeledContent("全局热键") {
                    HStack(spacing: 10) {
                        Text(statusModel.hotKeyBinding.displayString)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        StatusBadge(
                            level: hotKeyBadgeLevel,
                            text: hotKeyBadgeText
                        )
                    }
                }
            }

            Section("释义") {
                LabeledContent("当前来源") {
                    Text(statusModel.llmReady
                         ? "大模型 · \(statusModel.activeModel)"
                         : "系统词典（未配置 LLM）")
                }
                LabeledContent("API Key") {
                    Text(keyText)
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
                Text("诊断报告只含状态汇总与掩码密钥；日志可终端执行 log show --predicate 'subsystem == \"ClickToKnow\"' --last 1h 收集。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { statusModel.startMonitoring() }
        .onDisappear { statusModel.stopMonitoring() }
    }

    /// 暂停时热键未注册是预期状态，展示「已暂停」而非误导性的「注册失败」
    private var hotKeyBadgeLevel: StatusBadge.Level {
        if statusModel.hotKeyPaused { return .warn }
        return statusModel.hotKeyRegistered ? .ok : .bad
    }

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
        guard let masked = statusModel.maskedKey else { return "未配置" }
        switch statusModel.keySource {
        case .environment: return "\(masked) · 来自环境变量 / .env"
        case .keychain: return "\(masked) · 来自钥匙串"
        case .legacyUserDefaults: return "\(masked) · 来自本地存储（钥匙串不可用，已回退）"
        case .none: return masked
        }
    }
}
