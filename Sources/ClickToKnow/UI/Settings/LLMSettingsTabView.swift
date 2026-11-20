import SwiftUI

/// 连接测试状态（视图局部，不落盘）
enum LLMTestState: Equatable {
    case idle
    case testing
    case success(latencyMs: Int)
    case failure(reason: String)
}

/// 大模型配置：上方是添加/编辑表单（预设填充 + 协议 + 端点三件套 + 拉取模型 + 连接测试），
/// 下方是已配置的 API 列表（启用切换 / 点选编辑 / 删除）。
/// 表单为本地 @State，点「保存/添加」才写 AppConfig——沿用 ProviderFactory「按次读取即生效」机制，无需重启。
@MainActor
struct LLMSettingsTabView: View {
    @EnvironmentObject private var statusModel: AppStatusModel

    /// 已配置的 API 列表（保存/删除/切换后从 AppConfig 重新拉取）
    @State private var profiles: [APIProfile] = []
    /// 正在编辑的配置；nil 表示表单处于「新增」状态
    @State private var editingProfileID: UUID?

    @State private var presetID = ProviderPresets.customID
    @State private var apiProtocol: APIProtocol = .openAICompatible
    @State private var baseURL = ""
    @State private var apiKeyInput = ""
    @State private var model = ""

    @State private var testState: LLMTestState = .idle
    /// 连接测试的代际号：编辑表单/重新测试/保存都会 +1，过期结果回来时直接丢弃，避免旧结果覆盖新结果
    @State private var testGeneration = 0
    @State private var notice: String?

    /// 拉取到的模型目录；nil = 未拉取过（此时展示预设推荐 chips）
    @State private var fetchedModels: [String]?
    @State private var fetchingModels = false
    @State private var fetchError: String?

    @State private var loaded = false

    var body: some View {
        Form {
            Section(editingProfileID == nil ? "添加 API" : "编辑 API") {
                // 手动 Binding 而非 onChange：loadForEdit 程序化回填 presetID 时
                // 不应触发 applyPreset（否则刚载入的 model 会被预设推荐值覆盖）
                Picker("预设", selection: Binding(
                    get: { presetID },
                    set: { newID in
                        presetID = newID
                        applyPreset(newID)
                    }
                )) {
                    ForEach(ProviderPresets.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("API 协议")
                    Picker(selection: $apiProtocol) {
                        ForEach(APIProtocol.allCases) { apiProtocol in
                            Text(apiProtocol.displayName).tag(apiProtocol)
                        }
                    } label: {
                        EmptyView()
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: apiProtocol) { _ in invalidateEndpointDerivations() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Base URL")
                    endpointField(text: $baseURL, prompt: baseURLPlaceholder)
                        .onChange(of: baseURL) { _ in invalidateEndpointDerivations() }
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("API Key")
                    endpointSecureField(text: $apiKeyInput, prompt: "sk-...")
                        // env 密钥优先级最高且不可在此覆盖，禁用输入避免误导
                        .disabled(statusModel.keySource == .environment)
                        .onChange(of: apiKeyInput) { _ in invalidateEndpointDerivations() }
                    Text(keyHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Model")
                    HStack(spacing: 8) {
                        endpointField(text: $model, prompt: modelPlaceholder)
                            .onChange(of: model) { _ in resetTestState() }
                        Button { fetchModels() } label: {
                            if fetchingModels {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 52) // 与按钮文案等宽，避免拉取中布局跳动
                            } else {
                                Text("拉取模型")
                            }
                        }
                        .disabled(fetchingModels || baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let fetchError {
                        Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    if let fetchedModels {
                        if fetchedModels.isEmpty {
                            Text("该端点未返回可用模型")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(selection: $model) {
                                ForEach(fetchedModels, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            } label: {
                                EmptyView()
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text("已拉取 \(fetchedModels.count) 个模型，可直接选择")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else if !suggestedModels.isEmpty {
                        HStack(spacing: 8) {
                            Text("推荐:")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(suggestedModels, id: \.self) { name in
                                Button(name) {
                                    model = name
                                    resetTestState()
                                }
                                .controlSize(.small)
                            }
                            Spacer()
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button(testState == .testing ? "测试中…" : "测试连接") { runTest() }
                            .disabled(testState == .testing)
                        testResultView
                        Spacer()
                        if editingProfileID != nil {
                            Button("清除密钥") { clearKey() }
                                .disabled(editingProfileKeyMask == nil
                                          || statusModel.keySource == .environment)
                        }
                        Button(editingProfileID == nil ? "添加并启用" : "保存修改") { save() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                    }
                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("已配置的 API") {
                if profiles.isEmpty {
                    Text("暂无已配置的 API，在上方填写后点「添加并启用」")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles) { profile in
                    profileRow(profile)
                }
                if !profiles.isEmpty {
                    Button("新建 API 配置") { resetFormToNew() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !loaded { loadInitialState() }
            statusModel.refresh()
        }
    }

    // MARK: - 已配置列表

    @ViewBuilder
    private func profileRow(_ profile: APIProfile) -> some View {
        HStack(spacing: 10) {
            Button {
                activate(profile)
            } label: {
                Image(systemName: isActive(profile) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive(profile) ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive(profile) ? "当前使用的 API" : "设为当前使用")

            Button {
                loadForEdit(profile)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
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
                        if AppConfig.shared.storedKeyMask(for: profile) != nil
                            || AppConfig.shared.apiKeyFromEnvironment {
                            Image(systemName: "key.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("已配置密钥")
                        }
                        if editingProfileID == profile.id {
                            Text("编辑中")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(profile.baseURL)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("载入上方表单编辑")

            Button(role: .destructive) {
                removeProfile(profile)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除该配置（连同其密钥）")
        }
    }

    private func isActive(_ profile: APIProfile) -> Bool {
        AppConfig.shared.activeProfile?.id == profile.id
    }

    // MARK: - 子视图与辅助

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .success(let latencyMs):
            Label("连接成功 · \(latencyMs) ms", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .failure(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    /// 字段小标题：标签置顶、输入框占满整行，避免 LabeledContent 把输入框挤到右侧变窄
    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// macOS 26 grouped Form 的两个坑，必须同时避开输入框才能占满整行、占位符回到框内：
    /// 1. TextField 首参会被当成「行标签」渲染在输入框左侧（而非框内占位符）→ 用 prompt: 传占位符 + EmptyView 标签
    /// 2. Form 行里的输入框默认右对齐、按内容收缩宽度 → labelsHidden + leading 对齐 + maxWidth
    private func endpointField(text: Binding<String>, prompt: String) -> some View {
        TextField(text: text, prompt: Text(prompt)) { EmptyView() }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 同 endpointField，SecureField 版本
    private func endpointSecureField(text: Binding<String>, prompt: String) -> some View {
        SecureField(text: text, prompt: Text(prompt)) { EmptyView() }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestedModels: [String] {
        ProviderPresets.all.first { $0.id == presetID }?.suggestedModels ?? []
    }

    /// 占位符随协议切换，避免 Anthropic/Gemini 协议下还提示 deepseek 的端点/模型名
    private var baseURLPlaceholder: String {
        switch apiProtocol {
        case .openAICompatible: return "https://api.deepseek.com"
        case .openAIResponses: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    private var modelPlaceholder: String {
        switch apiProtocol {
        case .openAICompatible: return "如 deepseek-chat / qwen-plus"
        case .openAIResponses: return "如 gpt-4o-mini"
        case .anthropic: return "如 claude-haiku-4-5 / claude-sonnet-4-5"
        case .gemini: return "如 gemini-2.5-flash"
        }
    }

    /// 正在编辑的配置（可能已被删除，取不到时视为新增）
    private var editingProfile: APIProfile? {
        profiles.first { $0.id == editingProfileID }
    }

    /// 正在编辑配置的已存密钥掩码（控制「清除密钥」可用性）
    private var editingProfileKeyMask: String? {
        guard let editingProfile else { return nil }
        return AppConfig.shared.storedKeyMask(for: editingProfile)?.masked
    }

    /// 密钥来源提示：掩码回显 + 来源说明；密钥永不以明文出现在 UI
    private var keyHint: String {
        if statusModel.keySource == .environment {
            return "密钥已由环境变量 / .env 提供（\(statusModel.maskedKey ?? "")），对所有配置优先生效"
        }
        if let editingProfile, let stored = AppConfig.shared.storedKeyMask(for: editingProfile) {
            return stored.legacy
                ? "已保存：\(stored.masked)（本地存储，钥匙串不可用已回退）；建议重新输入保存一次"
                : "已保存：\(stored.masked)（钥匙串）；留空保存表示保持不变"
        }
        return "未配置密钥；全部留空则使用 macOS 系统词典兜底"
    }

    // MARK: - 行为

    private func loadInitialState() {
        profiles = AppConfig.shared.apiProfiles
        if let active = AppConfig.shared.activeProfile {
            loadForEdit(active)
        }
        loaded = true
    }

    private func loadForEdit(_ profile: APIProfile) {
        editingProfileID = profile.id
        apiProtocol = profile.apiProtocol
        baseURL = profile.baseURL
        model = profile.model
        presetID = ProviderPresets.matching(baseURL: profile.baseURL)?.id ?? ProviderPresets.customID
        // 密钥不回显明文：已有密钥经掩码提示展示，输入框留空 = 保持不变
        apiKeyInput = ""
        fetchedModels = nil
        fetchError = nil
        resetTestState()
        notice = nil
    }

    /// 表单重置为「新增」状态
    private func resetFormToNew() {
        editingProfileID = nil
        presetID = ProviderPresets.customID
        apiProtocol = .openAICompatible
        baseURL = ""
        model = ""
        apiKeyInput = ""
        fetchedModels = nil
        fetchError = nil
        resetTestState()
        notice = nil
    }

    private func applyPreset(_ id: String) {
        invalidateEndpointDerivations()
        notice = nil
        guard let preset = ProviderPresets.all.first(where: { $0.id == id }),
              preset.id != ProviderPresets.customID else { return }
        baseURL = preset.baseURL
        apiProtocol = preset.apiProtocol
        if !preset.suggestedModels.contains(model) {
            model = preset.suggestedModels.first ?? model
        }
    }

    /// 端点三要素（协议/URL/密钥）变动后：测试结果与拉取的模型目录一并作废
    private func invalidateEndpointDerivations() {
        resetTestState()
        fetchedModels = nil
        fetchError = nil
    }

    /// 表单当前值对应的密钥：输入框优先，留空代入该配置已存密钥（含 env），与实际划词行为一致
    private func effectiveFormKey() -> String {
        let input = apiKeyInput.trimmingCharacters(in: .whitespaces)
        if !input.isEmpty { return input }
        return AppConfig.shared.effectiveAPIKey(for: editingProfile ?? AppConfig.shared.activeProfile)
    }

    /// 用表单当前值测试（而非已保存值），保存前即可发现问题
    private func runTest() {
        testGeneration += 1
        let generation = testGeneration
        testState = .testing
        notice = nil
        Task { @MainActor in
            let result = await LLMConnectionTester().test(
                baseURL: baseURL,
                apiKey: effectiveFormKey(),
                model: model,
                apiProtocol: apiProtocol
            )
            // 表单已被修改或又发起了新测试：当前结果已过期，丢弃，避免旧结果覆盖新状态
            guard generation == testGeneration else { return }
            switch result {
            case .success(let latencyMs):
                testState = .success(latencyMs: latencyMs)
            case .failure(let reason):
                testState = .failure(reason: reason)
            }
        }
    }

    private func fetchModels() {
        fetchingModels = true
        fetchError = nil
        Task { @MainActor in
            do {
                let models = try await ModelCatalogFetcher().fetch(
                    baseURL: baseURL,
                    apiKey: effectiveFormKey(),
                    apiProtocol: apiProtocol
                )
                fetchingModels = false
                fetchedModels = models
                // 当前模型不在目录里时顺手套用第一个，减少一次手动选择
                if let first = models.first, !models.contains(model) {
                    model = first
                    resetTestState()
                }
            } catch {
                fetchingModels = false
                fetchedModels = nil
                fetchError = (error as? InterpretationError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    /// 表单变动后作废进行中的测试结果，并清空内联结果区
    private func resetTestState() {
        testGeneration += 1
        testState = .idle
    }

    private func save() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://") else {
            notice = "❌ Base URL 需以 http:// 或 https:// 开头，未保存"
            return
        }
        guard !trimmedModel.isEmpty else {
            notice = "❌ 请填写 Model（或点「拉取模型」选择），未保存"
            return
        }
        let config = AppConfig.shared
        let profile = config.upsertProfile(APIProfile(
            id: editingProfileID ?? UUID(),
            apiProtocol: apiProtocol,
            baseURL: trimmedURL,
            model: trimmedModel
        ))
        config.activeProfileID = profile.id // 保存即启用，与「按次读取即生效」一致
        let keyInput = apiKeyInput.trimmingCharacters(in: .whitespaces)
        if !keyInput.isEmpty {
            config.setAPIKey(keyInput) // 优先钥匙串，失败内部自动回退本地存储
        }
        // 密钥留空 = 保持已存密钥不变（清除走专门按钮，避免误清）
        apiKeyInput = ""
        editingProfileID = profile.id
        profiles = config.apiProfiles
        notice = config.apiKeySource == .legacyUserDefaults
            ? "✅ 已保存并启用（钥匙串不可用，密钥回退本地存储）"
            : "✅ 已保存并启用"
        statusModel.refresh()
    }

    private func activate(_ profile: APIProfile) {
        AppConfig.shared.activeProfileID = profile.id
        profiles = AppConfig.shared.apiProfiles
        notice = "已切换当前使用的 API：\(profile.model)"
        statusModel.refresh()
    }

    private func removeProfile(_ profile: APIProfile) {
        AppConfig.shared.deleteProfile(id: profile.id)
        if editingProfileID == profile.id {
            resetFormToNew()
        }
        profiles = AppConfig.shared.apiProfiles
        notice = "已删除配置：\(profile.model)"
        statusModel.refresh()
    }

    private func clearKey() {
        guard let editingProfile else { return }
        let cleared = AppConfig.shared.clearAPIKey(for: editingProfile)
        statusModel.refresh()
        notice = cleared
            ? "已清除该配置的密钥"
            : "⚠️ 钥匙串删除失败，密钥可能仍生效，请稍后重试"
    }
}
