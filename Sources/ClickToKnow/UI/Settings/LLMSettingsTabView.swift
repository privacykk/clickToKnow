import SwiftUI

/// 大模型配置：顶部是「当前使用」结论卡（状态与状态总览同一口径），
/// 下方是已配置的 API 列表（点行编辑 / 圆点切换启用 / 删除需确认），
/// 新增与编辑统一走弹窗（LLMProfileEditorSheet），避免长表单常驻把列表挤到屏幕外。
@MainActor
struct LLMSettingsTabView: View {
    @EnvironmentObject private var statusModel: AppStatusModel

    /// 已配置的 API 列表（保存/删除/切换后从 AppConfig 重新拉取）
    @State private var profiles: [APIProfile] = []

    /// 弹窗编辑目标；nil = 不显示弹窗
    @State private var editorTarget: EditorTarget?
    /// 待确认删除的配置
    @State private var pendingDeletion: APIProfile?
    /// 操作结果提示（保存/切换/删除）
    @State private var notice: String?

    /// 弹窗身份：每次打开都生成新 id，保证「同一配置连续编辑」也能重新呈现
    private struct EditorTarget: Identifiable {
        let id = UUID()
        let profile: APIProfile?
    }

    var body: some View {
        Form {
            Section {
                statusCard
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("已配置的 API") {
                if profiles.isEmpty {
                    Text("还没有配置。添加后可一键切换、随时编辑，保存即生效。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
                Button {
                    editorTarget = EditorTarget(profile: nil)
                } label: {
                    Label("添加 API 配置…", systemImage: "plus")
                }
                .help("新建一套端点 / 模型配置")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            reload()
            statusModel.refresh()
        }
        .sheet(item: $editorTarget, onDismiss: {
            // 弹窗里也可能清除密钥/保存配置，关闭后统一重新拉取，列表不会显示过期信息
            reload()
            statusModel.refresh()
        }) { target in
            LLMProfileEditorSheet(existing: target.profile, statusModel: statusModel) { result in
                handleSaved(result)
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { profile in
            Button("删除", role: .destructive) { removeProfile(profile) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("该配置的钥匙串密钥会一并删除。")
        }
    }

    // MARK: - 当前使用结论卡

    private var activeProfile: APIProfile? {
        AppConfig.shared.activeProfile
    }

    private var statusCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: cardIcon)
                .font(.system(size: 24))
                .foregroundStyle(cardColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(cardTitle)
                    .font(.headline)
                Text(cardDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let activeProfile, statusModel.llmStatus != .ready {
                Button("补全配置") { editorTarget = EditorTarget(profile: activeProfile) }
            } else if activeProfile == nil {
                Button("添加配置") { editorTarget = EditorTarget(profile: nil) }
            }
        }
        .padding(.vertical, 4)
    }

    private var cardIcon: String {
        switch statusModel.llmStatus {
        case .ready: return "checkmark.seal.fill"
        case .missingKey: return "exclamationmark.triangle.fill"
        case .notConfigured: return activeProfile == nil ? "sparkles" : "exclamationmark.triangle.fill"
        }
    }

    private var cardColor: Color {
        switch statusModel.llmStatus {
        case .ready: return .green
        case .missingKey: return .orange
        case .notConfigured: return activeProfile == nil ? .secondary : .orange
        }
    }

    private var cardTitle: String {
        switch statusModel.llmStatus {
        case .ready: return "大模型已就绪"
        case .missingKey: return "已配置，但还缺 API Key"
        case .notConfigured:
            return activeProfile == nil ? "尚未添加 API 配置" : "当前配置不完整"
        }
    }

    private var cardDetail: String {
        switch statusModel.llmStatus {
        case .ready:
            return "当前使用「\(statusModel.activeModel)」· \(statusModel.activeBaseURL)"
        case .missingKey:
            return "「\(statusModel.activeModel)」已保存为当前使用，填入密钥后立即生效；否则划词仍走系统词典。"
        case .notConfigured:
            return activeProfile == nil
                ? "现在由 macOS 系统词典兜底；添加配置后划词释义改由大模型生成。"
                : "缺少端点或模型，请打开编辑补全后保存。"
        }
    }

    // MARK: - 已配置列表

    private func profileRow(_ profile: APIProfile) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                activate(profile)
            } label: {
                Image(systemName: isActive(profile) ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isActive(profile) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive(profile) ? "当前使用中" : "设为当前使用")
            .padding(.top, 2)

            Button {
                editorTarget = EditorTarget(profile: profile)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.model.isEmpty ? "（未设模型）" : profile.model)
                            .font(.callout)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(profile.apiProtocol.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                        if hasStoredKey(profile) {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("已配置密钥")
                        }
                    }
                    Text(profile.baseURL)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(rowStatusColor(profile))
                            .frame(width: 6, height: 6)
                        Text(rowStatusText(profile))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("编辑该配置")

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button(role: .destructive) {
                pendingDeletion = profile
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除该配置（连同其密钥）")
        }
        .padding(.vertical, 2)
    }

    /// 该配置是否当前启用
    private func isActive(_ profile: APIProfile) -> Bool {
        activeProfile?.id == profile.id
    }

    /// 该配置是否已有可用密钥（环境变量对所有配置生效）
    private func hasStoredKey(_ profile: APIProfile) -> Bool {
        AppConfig.shared.storedKeyMask(for: profile) != nil || AppConfig.shared.apiKeyFromEnvironment
    }

    private func rowStatusColor(_ profile: APIProfile) -> Color {
        switch AppConfig.shared.llmStatus(for: profile) {
        case .ready: return .green
        case .missingKey: return .orange
        case .notConfigured: return .red
        }
    }

    /// 行内状态：启用与否 + 可用性，与状态总览使用同一判定
    private func rowStatusText(_ profile: APIProfile) -> String {
        let prefix = isActive(profile) ? "使用中" : "未启用"
        switch AppConfig.shared.llmStatus(for: profile) {
        case .ready: return "\(prefix) · 可用"
        case .missingKey: return "\(prefix) · 缺少密钥，划词回落系统词典"
        case .notConfigured: return "\(prefix) · 配置不完整"
        }
    }

    private var deletionTitle: String {
        let name = pendingDeletion?.model ?? ""
        return "删除配置「\(name)」？"
    }

    // MARK: - 行为

    /// 从 AppConfig 重新拉取列表（任何写操作后都走这里，避免内存与磁盘不一致）
    private func reload() {
        profiles = AppConfig.shared.apiProfiles
    }

    /// 弹窗保存成功：刷新列表并给出结果提示
    private func handleSaved(_ result: LLMProfileSaveResult) {
        reload()
        var text = result.activated
            ? "已保存并启用「\(result.model)」"
            : "已保存「\(result.model)」（当前使用未变）"
        if result.keychainFallback {
            text += "；钥匙串不可用，密钥已回退本地存储"
        }
        if result.keySaveFailed {
            text += "；⚠️ 密钥未能写入钥匙串，请切换为当前使用后重新填写"
        }
        notice = text
        statusModel.refresh()
    }

    /// 一键切换启用配置
    private func activate(_ profile: APIProfile) {
        guard !isActive(profile) else { return }
        AppConfig.shared.activeProfileID = profile.id
        reload()
        notice = "已切换当前使用的 API：「\(profile.model)」"
        statusModel.refresh()
    }

    /// 删除配置（连同其钥匙串密钥）；正在编辑/已启用都会被妥善收尾
    private func removeProfile(_ profile: APIProfile) {
        let config = AppConfig.shared
        let wasActive = isActive(profile)
        config.deleteProfile(id: profile.id)
        reload()
        if wasActive {
            if let next = config.activeProfile {
                notice = "已删除「\(profile.model)」；当前改用「\(next.model)」"
            } else {
                notice = "已删除「\(profile.model)」；已无配置，划词将回落系统词典"
            }
        } else {
            notice = "已删除「\(profile.model)」"
        }
        statusModel.refresh()
    }
}
