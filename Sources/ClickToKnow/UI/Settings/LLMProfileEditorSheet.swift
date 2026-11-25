import SwiftUI

/// 连接测试状态（视图局部，不落盘）
enum LLMTestState: Equatable {
    case idle
    /// 测试进行中
    case testing
    /// 成功（携带毫秒延迟）
    case success(latencyMs: Int)
    /// 失败（携带可展示原因）
    case failure(reason: String)
}

/// 编辑弹窗的保存结果：父视图据此刷新列表并给出提示
struct LLMProfileSaveResult {
    /// 保存后的模型名
    let model: String
    /// 是否同时设为当前使用
    let activated: Bool
    let sessionOnly: Bool
}

/// 单个 API 配置的编辑弹窗：新增与编辑共用，保存后由父视图刷新列表。
/// 表单为本地 @State，点「保存」才写 AppConfig——沿用 ProviderFactory「按次读取即生效」机制，无需重启。
@MainActor
struct LLMProfileEditorSheet: View {
    /// 正在编辑的配置；nil = 新增
    private let existing: APIProfile?
    @ObservedObject private var statusModel: AppStatusModel
    /// 保存成功回调（弹窗自行关闭）
    private let onSaved: (LLMProfileSaveResult) -> Void

    @Environment(\.dismiss) private var dismiss

    /// 表单字段：预设 / 协议 / 端点三件套（密钥仅输入用，不直接回显）
    @State private var presetID: String
    @State private var apiProtocol: APIProtocol
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKeyInput = ""
    @State private var keychainSaveFailed = false

    /// 连接测试状态
    @State private var testState: LLMTestState = .idle
    /// 连接测试代际号：表单变动/重新测试/保存都会 +1，过期结果回来时直接丢弃
    @State private var testGeneration = 0

    /// 拉取到的模型目录；nil = 未拉取过（此时展示预设推荐 chips）
    @State private var fetchedModels: [String]?
    @State private var fetchingModels = false
    @State private var fetchError: String?
    /// 拉取代际号：端点/协议/密钥变动、重新拉取都会 +1，
    /// 旧端点的慢响应回来时据此丢弃，避免它覆盖新端点的列表与模型选择
    @State private var fetchGeneration = 0

    /// 校验失败与「清除密钥」等即时提示
    @State private var notice: String?
    /// notice 是否为错误（错误红色，普通提示次要色）
    @State private var noticeIsError = false

    init(
        existing: APIProfile?,
        statusModel: AppStatusModel,
        onSaved: @escaping (LLMProfileSaveResult) -> Void
    ) {
        self.existing = existing
        self.statusModel = statusModel
        self.onSaved = onSaved
        _apiProtocol = State(initialValue: existing?.apiProtocol ?? .openAICompatible)
        _baseURL = State(initialValue: existing?.baseURL ?? "")
        _model = State(initialValue: existing?.model ?? "")
        _presetID = State(
            initialValue: existing.flatMap { ProviderPresets.matching(baseURL: $0.baseURL)?.id }
                ?? ProviderPresets.customID
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section("供应商") {
                    field("预设供应商") {
                        Picker(selection: Binding(
                            get: { presetID },
                            set: { newID in
                                presetID = newID
                                applyPreset(newID)
                            }
                        )) {
                            ForEach(ProviderPresets.all) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        } label: {
                            EmptyView()
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section("连接") {
                    field("API 协议") {
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

                    field("Base URL") {
                        endpointField(text: $baseURL, prompt: baseURLPlaceholder)
                            .onChange(of: baseURL) { _ in invalidateEndpointDerivations() }
                    }

                    field("API Key") {
                        endpointSecureField(text: $apiKeyInput, prompt: existingKeyMask == nil ? "sk-..." : "留空保持不变")
                            .disabled(statusModel.keySource == .environment)
                            .onChange(of: apiKeyInput) { _ in invalidateEndpointDerivations() }
                        Text(keyHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let existing, statusModel.keySource != .environment {
                            if needsKeyAuthorization {
                                Button("授权访问密钥") { authorizeKey(for: existing) }
                                    .controlSize(.small)
                            } else if AppConfig.shared.canMigrateLegacyAPIKey(for: existing) {
                                Button("迁移旧密钥到钥匙串") { authorizeKey(for: existing) }
                                    .controlSize(.small)
                            }
                        }
                        if (existingKeyMask != nil || needsKeyAuthorization) && statusModel.keySource != .environment {
                            Button("清除已存密钥") { clearKey() }
                                .controlSize(.small)
                        }
                    }
                }

                Section("模型") {
                    field("Model") {
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
                    HStack(spacing: 10) {
                        Button(testState == .testing ? "测试中…" : "测试连接") { runTest() }
                            .disabled(testState == .testing)
                        testResultView
                        Spacer()
                    }
                    Text("以表单当前值发起一次最小请求；密钥无效、模型名写错会在这里直接暴露，不必等划词失败。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 520, height: 600)
    }

    // MARK: - 头尾

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: existing == nil ? "plus.circle.fill" : "slider.horizontal.3")
                .foregroundStyle(Color.accentColor)
            Text(existing == nil ? "添加 API 配置" : "编辑 API 配置")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// 底部操作区：校验提示 + 缺密钥预警 + 取消 / 仅保存 / 保存并启用
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(noticeIsError ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if keychainSaveFailed, !LLMProviderSupport.sanitizedAPIKey(apiKeyInput).isEmpty {
                HStack {
                    if existing != nil {
                        Button("仅本次运行使用") { commit(activate: false, sessionOnly: true) }
                    }
                    Button("仅本次运行使用并启用") { commit(activate: true, sessionOnly: true) }
                }
            }
            if missingKeyWarning {
                Label("该供应商需要 API Key：现在保存，划词仍会回落系统词典。", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if existing != nil {
                    Button("仅保存") { commit(activate: false) }
                        .help("保存配置但不切换当前使用")
                }
                Button(existing == nil ? "添加并启用" : "保存并启用") { commit(activate: true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
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

    /// 标题置顶、控件占满整行的字段块（与列表页视觉一致）
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            content()
        }
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

    /// 已存密钥掩码（nil = 该配置没有密钥）
    private var existingKeyMask: String? {
        guard let existing else { return nil }
        return AppConfig.shared.storedKeyMask(for: existing)
    }

    private var existingKeySource: AppConfig.APIKeySource {
        guard let existing else { return .none }
        return AppConfig.shared.storedKeySource(for: existing)
    }

    private var needsKeyAuthorization: Bool {
        existingKeySource == .keychainNeedsAuthorization
    }

    /// 密钥来源提示：掩码回显 + 来源说明；密钥永不以明文出现在 UI
    private var keyHint: String {
        if statusModel.keySource == .environment {
            return "密钥已由环境变量 / .env 提供（\(statusModel.maskedKey ?? "")），对所有配置优先生效"
        }
        if storedKeyBlockedByHostChange {
            return "端点主机已变更：已存密钥不会自动用于新地址，请重新输入密钥后测试/拉取"
        }
        if needsKeyAuthorization {
            return "需要授权访问钥匙串。授权后可继续使用已保存的密钥。"
        }
        if let stored = existingKeyMask {
            switch existingKeySource {
            case .legacyUserDefaults: return "\(stored) · 旧版明文存储，可迁移到钥匙串"
            case .session: return "\(stored) · 仅本次运行使用，退出后失效"
            default: return "\(stored) · 已保存到钥匙串，留空保持不变"
            }
        }
        return "尚未保存密钥；若该供应商必须鉴权，划词会回落 macOS 系统词典"
    }

    /// 保存前的缺密钥预警：端点/模型已填好、该供应商要密钥，但没有输入也没有已存密钥
    private var missingKeyWarning: Bool {
        guard LLMProviderSupport.sanitizedAPIKey(apiKeyInput).isEmpty,
              existingKeyMask == nil,
              !needsKeyAuthorization,
              statusModel.keySource != .environment,
              !baseURL.trimmingCharacters(in: .whitespaces).isEmpty,
              !model.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !(ProviderPresets.matching(baseURL: baseURL)?.apiKeyOptional ?? false)
    }

    // MARK: - 行为

    /// 应用预设：填充端点/协议/推荐模型（「自定义」不填充）
    private func applyPreset(_ id: String) {
        invalidateEndpointDerivations()
        notice = nil
        noticeIsError = false
        guard let preset = ProviderPresets.all.first(where: { $0.id == id }),
              preset.id != ProviderPresets.customID else { return }
        baseURL = preset.baseURL
        apiProtocol = preset.apiProtocol
        if !preset.suggestedModels.contains(model) {
            model = preset.suggestedModels.first ?? model
        }
    }

    /// 端点三要素（协议/URL/密钥）变动后：测试结果、拉取的模型目录与在途拉取一并作废
    private func invalidateEndpointDerivations() {
        keychainSaveFailed = false
        resetTestState()
        // 在途的拉取结果已无意义：换代并解除 loading，旧任务回来时会被代际校验丢弃
        fetchGeneration += 1
        fetchingModels = false
        fetchedModels = nil
        fetchError = nil
    }

    /// 表单当前值对应的密钥。
    ///
    /// 规则刻意保守：**新增配置一律不借用任何已存密钥**。否则 A 有密钥、新增 B 不填密钥时，
    /// 「测试连接 / 拉取模型」会把 A 的密钥发往 B 的地址，而保存 B 时并不会复制该密钥，
    /// 测试通过与真实划词行为也不一致。编辑已有配置时只用它自己的密钥（含归属它的遗留存储），
    /// 且端点主机变了就不再自动沿用——密钥是按端点授权出去的。
    private func effectiveFormKey() -> String {
        let input = LLMProviderSupport.sanitizedAPIKey(apiKeyInput)
        if !input.isEmpty { return input }
        let config = AppConfig.shared
        // 环境变量/.env 对所有配置优先生效，与划词读取链一致
        if config.apiKeyFromEnvironment { return config.effectiveAPIKey(for: nil) }
        guard let existing, LLMProviderSupport.sameEndpointHost(existing.baseURL, baseURL) else { return "" }
        return config.effectiveAPIKey(for: existing)
    }

    /// 端点主机已改动且存在可沿用的已存密钥：测试/拉取不会带上该密钥，需要提示用户重新确认
    private var storedKeyBlockedByHostChange: Bool {
        guard let existing, existingKeyMask != nil || needsKeyAuthorization else { return false }
        guard LLMProviderSupport.sanitizedAPIKey(apiKeyInput).isEmpty else { return false }
        return !LLMProviderSupport.sameEndpointHost(existing.baseURL, baseURL)
    }

    private func authorizeKey(for profile: APIProfile) {
        let authorized = AppConfig.shared.authorizeAPIKey(for: profile)
        statusModel.refresh()
        notice = authorized ? "钥匙串密钥可用" : "钥匙串密钥暂不可用，请确认已授权或解锁钥匙串后重试。"
        noticeIsError = !authorized
    }

    /// 测试和拉取是显式操作，且只为同一端点读取它自己的密钥。
    private func prepareFormKey() -> Bool {
        guard let existing, !AppConfig.shared.apiKeyFromEnvironment, needsKeyAuthorization,
              LLMProviderSupport.sanitizedAPIKey(apiKeyInput).isEmpty,
              LLMProviderSupport.sameEndpointHost(existing.baseURL, baseURL) else { return true }
        authorizeKey(for: existing)
        return !needsKeyAuthorization
    }

    /// 用表单当前值测试（而非已保存值），保存前即可发现问题
    private func runTest() {
        guard prepareFormKey() else { return }
        testGeneration += 1
        let generation = testGeneration
        testState = .testing
        notice = nil
        noticeIsError = false
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

    /// 拉取模型目录：成功后当前模型不在目录里则自动套用第一个。
    /// 与连接测试一样走代际校验：端点 A 的慢响应不得覆盖已切到端点 B 的列表与模型选择
    private func fetchModels() {
        guard prepareFormKey() else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        // 输入快照：请求参数与「回来时该不该采用」都以发起时刻为准
        let requestBaseURL = baseURL
        let requestProtocol = apiProtocol
        let requestKey = effectiveFormKey()
        fetchingModels = true
        fetchError = nil
        Task { @MainActor in
            do {
                let models = try await ModelCatalogFetcher().fetch(
                    baseURL: requestBaseURL,
                    apiKey: requestKey,
                    apiProtocol: requestProtocol
                )
                // 表单已变动或又发起了新拉取：当前结果已过期，丢弃，且不动 loading 标记
                guard generation == fetchGeneration else { return }
                fetchingModels = false
                fetchedModels = models
                // 当前模型不在目录里时顺手套用第一个，减少一次手动选择
                if let first = models.first, !models.contains(model) {
                    model = first
                    resetTestState()
                }
            } catch {
                guard generation == fetchGeneration else { return }
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

    /// 校验并保存配置，只有用户主动选择时才仅在内存中使用新密钥。
    private func commit(activate: Bool, sessionOnly: Bool = false) {
        notice = nil
        noticeIsError = false
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard (trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://")),
              !LLMProviderSupport.endpointHost(trimmedURL).isEmpty else {
            notice = "请输入有效的 HTTP 或 HTTPS Base URL"
            noticeIsError = true
            return
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard !trimmedModel.isEmpty else {
            notice = "请填写 Model（或点「拉取模型」选择），尚未保存"
            noticeIsError = true
            return
        }

        let config = AppConfig.shared
        let profile = APIProfile(
            id: existing?.id ?? UUID(),
            apiProtocol: apiProtocol,
            baseURL: trimmedURL,
            model: trimmedModel
        )
        let keyInput = LLMProviderSupport.sanitizedAPIKey(apiKeyInput)
        let savedProfile: APIProfile
        switch config.saveEditedProfile(profile, key: keyInput, sessionOnly: sessionOnly) {
        case .oldKeyNotCleared:
            notice = "无法确认旧端点的密钥已清除。请先清除密钥，再保存新的 Base URL。"
            noticeIsError = true
            return
        case .keyNotSaved:
            notice = "钥匙串写入失败。可以授权后重试，或仅在本次运行中使用该密钥。"
            noticeIsError = true
            keychainSaveFailed = true
            return
        case .saved(let saved):
            savedProfile = saved
        }
        if activate {
            config.activeProfileID = savedProfile.id
        }

        onSaved(LLMProfileSaveResult(
            model: profile.model,
            activated: activate,
            sessionOnly: sessionOnly
        ))
        dismiss()
    }

    /// 清除正在编辑配置的已存密钥（结果经 notice 提示，失败需如实告知）
    private func clearKey() {
        guard let existing else { return }
        let cleared = AppConfig.shared.clearAPIKey(for: existing)
        notice = cleared ? "已清除该配置的密钥" : "钥匙串删除失败，密钥可能仍生效，请稍后重试"
        noticeIsError = !cleared
    }
}
