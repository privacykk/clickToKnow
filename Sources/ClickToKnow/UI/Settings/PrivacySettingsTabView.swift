import SwiftUI

@MainActor
struct PrivacySettingsTabView: View {
    private let config = AppConfig.shared
    @State private var localOnly = AppConfig.shared.localDictionaryOnly
    @State private var sendsContext = AppConfig.shared.sendsQueryContext
    @State private var recordsHistory = AppConfig.shared.recordsQueryHistory
    @State private var blockedApps = AppConfig.shared.customBlacklistedBundleIDs
    @State private var bundleID = ""
    @State private var confirmsClearHistory = false

    private var candidate: String { bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("查询数据") {
                Toggle("查询仅使用 macOS 系统词典", isOn: $localOnly)
                    .onChange(of: localOnly) { config.localDictionaryOnly = $0 }
                Toggle("向大模型发送选区前后文", isOn: $sendsContext)
                    .disabled(localOnly)
                    .onChange(of: sendsContext) { config.sendsQueryContext = $0 }
                Text("关闭前后文后，大模型查询仍会发送选中的文字。手动测试连接和拉取模型仍会访问配置的端点。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("历史记录") {
                Toggle("保存查询历史", isOn: $recordsHistory)
                    .onChange(of: recordsHistory) { config.recordsQueryHistory = $0 }
                Button("清空历史记录…", role: .destructive) { confirmsClearHistory = true }
            }
            Section("禁止取词的应用") {
                HStack {
                    TextField("应用 Bundle ID", text: $bundleID, prompt: Text("com.example.app"))
                        .onSubmit(addBundle)
                    Button("添加", action: addBundle)
                        .disabled(!canAddBundle)
                }
                ForEach(blockedApps, id: \.self) { id in
                    LabeledContent(id) {
                        Button("移除") {
                            config.customBlacklistedBundleIDs.removeAll { $0 == id }
                            blockedApps = config.customBlacklistedBundleIDs
                        }
                        .accessibilityLabel("移除 \(id)")
                    }
                }
                Text("内置密码管理类应用始终禁止取词。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清空全部历史记录？", isPresented: $confirmsClearHistory) {
            Button("清空历史记录", role: .destructive) { HistoryStore.shared.removeAll() }
        }
    }

    private var canAddBundle: Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
            && !config.blacklistedBundleIDs.contains(candidate)
    }

    private func addBundle() {
        guard canAddBundle else { return }
        config.customBlacklistedBundleIDs.append(candidate)
        blockedApps = config.customBlacklistedBundleIDs
        bundleID = ""
    }
}
