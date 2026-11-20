import SwiftUI

/// 快捷键设置：当前绑定展示 + 录制新绑定 + 恢复默认。
/// 流程：捕获 → 校验修饰键 → SelectionMonitor 试注册 → 成功才持久化（失败自动保持原绑定）。
@MainActor
struct HotKeyTabView: View {
    @EnvironmentObject private var statusModel: AppStatusModel

    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        Form {
            Section("当前绑定") {
                LabeledContent("全局热键") {
                    HStack(spacing: 10) {
                        Text(statusModel.hotKeyBinding.displayString)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        StatusBadge(
                            level: statusModel.hotKeyPaused
                                ? .warn
                                : (statusModel.hotKeyRegistered ? .ok : .bad),
                            text: statusModel.hotKeyPaused
                                ? "已暂停"
                                : (statusModel.hotKeyRegistered ? "已注册" : "注册失败")
                        )
                    }
                }
            }

            Section("修改") {
                LabeledContent("新快捷键") {
                    HotKeyRecorderField(
                        placeholder: statusModel.hotKeyBinding.displayString,
                        onCapture: { captured in apply(captured) },
                        onCancel: {
                            errorMessage = nil
                            successMessage = nil
                        }
                    )
                    .frame(width: 220, height: 28)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let successMessage {
                    Text(successMessage)
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                Button("恢复默认 \(CarbonKeyTranslator.defaultBinding.displayString)") {
                    apply(CarbonKeyTranslator.defaultBinding)
                }
            }

            Section {
                Text("需至少包含 ⌘ / ⌥ / ⌃ 之一。若组合被系统或其他应用占用，注册会失败并自动保留原绑定。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { statusModel.refresh() }
    }

    /// 试注册先行：reloadHotKey 返回 true 才持久化并广播；失败时内部已回滚，任何时刻热键可用
    private func apply(_ binding: HotKeyBinding) {
        errorMessage = nil
        successMessage = nil
        guard CarbonKeyTranslator.hasRequiredModifier(binding.carbonModifiers) else {
            errorMessage = "需至少包含 ⌘ / ⌥ / ⌃ 之一"
            return
        }
        guard let monitor = statusModel.selectionMonitor else {
            errorMessage = "运行时尚未就绪，请重新打开设置再试"
            return
        }
        if monitor.reloadHotKey(with: binding) {
            AppConfig.shared.hotKeyBinding = binding // 持久化 + 广播 .ctkHotKeyBindingChanged
            successMessage = "已改为 \(binding.displayString)"
        } else {
            errorMessage = "\(binding.displayString) 注册失败，可能被占用，已保留原绑定"
        }
        statusModel.refresh()
    }
}
