import SwiftUI

/// 快捷键设置：当前绑定（含注册状态）+ 录制新绑定 + 恢复默认。
/// 交互改为「捕获 → 展示待应用组合 → 应用/取消」两步：
/// 录制时按错一个键不会立刻改全局热键，确认后才试注册并持久化。
/// 注册流程：捕获 → 校验修饰键 → SelectionMonitor 试注册 → 成功才持久化（失败自动保持原绑定）。
@MainActor
struct HotKeyTabView: View {
    @EnvironmentObject private var statusModel: AppStatusModel

    /// 已录制但尚未应用的组合；nil = 没有待确认的修改
    @State private var pendingBinding: HotKeyBinding?
    /// 修改失败的提示文案
    @State private var errorMessage: String?
    /// 修改成功的提示文案
    @State private var successMessage: String?

    var body: some View {
        Form {
            Section("当前绑定") {
                HStack(spacing: 10) {
                    Text(statusModel.hotKeyBinding.displayString)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    StatusBadge(
                        level: statusModel.hotKeyPaused
                            ? .warn
                            : (statusModel.hotKeyRegistered ? .ok : .bad),
                        text: statusModel.hotKeyPaused
                            ? "已暂停"
                            : (statusModel.hotKeyRegistered ? "已注册" : "注册失败")
                    )
                    Spacer()
                    if statusModel.hotKeyPaused {
                        Text("可在菜单栏「暂停取词」处恢复")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("先选中文字，再按此组合键即可获取释义。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("修改快捷键") {
                Text("点击下方输入框开始录制，然后按下新的组合键（需包含 ⌘ / ⌥ / ⌃ 之一），Esc 取消录制。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HotKeyRecorderField(
                    placeholder: pendingBinding?.displayString ?? statusModel.hotKeyBinding.displayString,
                    onCapture: { captured in
                        // 只记录待应用组合，真正的热重注册留给「应用」按钮
                        pendingBinding = captured
                        errorMessage = nil
                        successMessage = nil
                    },
                    onCancel: {
                        pendingBinding = nil
                        errorMessage = nil
                        successMessage = nil
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 34)

                if let pendingBinding {
                    HStack(spacing: 10) {
                        Text("待应用：\(pendingBinding.displayString)")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        if pendingBinding == statusModel.hotKeyBinding {
                            Text("与当前绑定相同")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("取消") {
                            self.pendingBinding = nil
                            errorMessage = nil
                        }
                        Button(isSameAsCurrent(pendingBinding) ? "已生效" : "应用") {
                            apply(pendingBinding)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSameAsCurrent(pendingBinding))
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let successMessage {
                    Text(successMessage)
                        .font(.callout)
                        .foregroundStyle(.green)
                }
            }

            Section {
                Button("恢复默认 \(CarbonKeyTranslator.defaultBinding.displayString)") {
                    pendingBinding = nil
                    errorMessage = nil
                    successMessage = nil
                    apply(CarbonKeyTranslator.defaultBinding)
                }
                .disabled(statusModel.hotKeyBinding == CarbonKeyTranslator.defaultBinding && pendingBinding == nil)

                Text("若组合被系统或其他应用占用，应用会失败并自动保留原绑定，不会把热键改没。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { statusModel.refresh() }
    }

    /// 待应用组合是否就是当前绑定（此时无需再试注册）
    private func isSameAsCurrent(_ binding: HotKeyBinding) -> Bool {
        binding == statusModel.hotKeyBinding
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
            successMessage = "已改为 \(binding.displayString)，选中文字后即可使用"
            pendingBinding = nil
        } else {
            errorMessage = "\(binding.displayString) 注册失败，可能被系统或其他应用占用；原绑定「\(statusModel.hotKeyBinding.displayString)」仍在生效"
        }
        statusModel.refresh()
    }
}
