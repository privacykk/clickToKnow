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
    /// 密钥写入钥匙串失败（已回退本地存储，或非生效配置未能保存）
    let keychainFallback: Bool
    /// 非生效配置的密钥完全没能保存（不能回退本地明文，避免串到其他配置）
    let keySaveFailed: Bool
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

    /// 连接测试状态
    @State private var testState: LLMTestState = .idle
    /// 连接测试代际号：表单变动/重新测试/保存都会 +1，过期结果回来时直接丢弃
    @State private var testGeneration = 0

    /// 拉取到的模型目录；nil = 未拉取过（此时展示预设推荐 chips）
    @State private var fetchedModels: [String]?
    @State private var fetchingModels = false
    @State private var fetchError: String?

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
                        if existingKeyMask != nil && statusModel.keySource != .environment {
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
    private var existingKeyMask: (masked: String, legacy: Bool)? {
        guard let existing else { return nil }
        return AppConfig.shared.storedKeyMask(for: existing)
    }

    /// 密钥来源提示：掩码回显 + 来源说明；密钥永不以明文出现在 UI
    private var keyHint: String {
        if statusModel.keySource == .environment {
            return "密钥已由环境变量 / .env 提供（\(statusModel.maskedKey ?? "")），对所有配置优先生效"
        }
        if let stored = existingKeyMask {
            return stored.legacy
                ? "已保存：\(stored.masked)（本地存储，钥匙串不可用已回退）；建议重新输入保存一次"
                : "已保存：\(stored.masked)（钥匙串）；留空保存表示保持不变"
        }
        return "尚未保存密钥；若该供应商必须鉴权，划词会回落 macOS 系统词典"
    }

    /// 保存前的缺密钥预警：端点/模型已填好、该供应商要密钥，但没有输入也没有已存密钥
    private var missingKeyWarning: Bool {
        guard LLMProviderSupport.sanitizedAPIKey(apiKeyInput).isEmpty,
              existingKeyMask == nil,
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

    /// 端点三要素（协议/URL/密钥）变动后：测试结果与拉取的模型目录一并作废
    private func invalidateEndpointDerivations() {
        resetTestState()
        fetchedModels = nil
        fetchError = nil
    }

    /// 表单当前值对应的密钥：输入框优先，留空代入该配置已存密钥（含 env），与实际划词行为一致。
    /// 输入值先清洗（剥空白含换行）：换行混入会令 CFNetwork 丢弃 Authorization 头，表现为「没传 key」
    private func effectiveFormKey() -> String {
        let input = LLMProviderSupport.sanitizedAPIKey(apiKeyInput)
        if !input.isEmpty { return input }
        return AppConfig.shared.effectiveAPIKey(for: existing ?? AppConfig.shared.activeProfile)
    }

    /// 用表单当前值测试（而非已保存值），保存前即可发现问题
    private func runTest() {
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

    /// 拉取模型目录：成功后当前模型不在目录里则自动套用第一个
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

    /// 校验并落库：upsert 配置 +（可选）设为启用；非空密钥写入钥匙串（内部自动回退）
    private func commit(activate: Bool) {
        notice = nil
        noticeIsError = false
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        guard trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://") else {
            notice = "Base URL 需以 http:// 或 https:// 开头，尚未保存"
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
        let profile = config.upsertProfile(APIProfile(
            id: existing?.id ?? UUID(),
            apiProtocol: apiProtocol,
            baseURL: trimmedURL,
            model: trimmedModel
        ))
        if activate {
            config.activeProfileID = profile.id
        }

        // 密钥留空 = 保持已存密钥不变（清除走专门按钮，避免误清）
        let keyInput = LLMProviderSupport.sanitizedAPIKey(apiKeyInput)
        var keychainFallback = false
        var keySaveFailed = false
        if !keyInput.isEmpty {
            // 落库后该配置可能本来就是当前使用项，因此以实际生效项判断回退语义
            let profileIsActive = config.activeProfile?.id == profile.id
            let savedToKeychain = config.setAPIKey(keyInput, for: profile)
            if !savedToKeychain {
                if profileIsActive {
                    keychainFallback = true
                } else {
                    keySaveFailed = true
                }
            }
        }

        onSaved(LLMProfileSaveResult(
            model: profile.model,
            activated: activate,
            keychainFallback: keychainFallback,
            keySaveFailed: keySaveFailed
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
