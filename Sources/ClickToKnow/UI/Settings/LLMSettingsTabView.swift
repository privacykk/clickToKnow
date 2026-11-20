import SwiftUI

/// 连接测试状态（视图局部，不落盘）
enum LLMTestState: Equatable {
    case idle
    case testing
    case success(latencyMs: Int)
    case failure(reason: String)
}

/// 大模型配置：预设供应商 + 端点三件套 + 连接测试 + 保存/清除。
/// 表单为本地 @State，点「保存」才写 AppConfig——沿用 ProviderFactory「按次读取即生效」机制，无需重启。
@MainActor
struct LLMSettingsTabView: View {
    @EnvironmentObject private var statusModel: AppStatusModel

    @State private var presetID = ProviderPresets.customID
    @State private var apiProtocol: APIProtocol = .openAICompatible
    @State private var baseURL = ""
    @State private var apiKeyInput = ""
    @State private var model = ""
    @State private var testState: LLMTestState = .idle
    /// 连接测试的代际号：编辑表单/重新测试/保存都会 +1，过期结果回来时直接丢弃，避免旧结果覆盖新结果
    @State private var testGeneration = 0
    @State private var notice: String?
    @State private var loaded = false

    var body: some View {
        Form {
            Section("供应商") {
                Picker("预设", selection: $presetID) {
                    ForEach(ProviderPresets.all) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: presetID) { newID in applyPreset(newID) }
            }

            Section("端点") {
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
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: apiProtocol) { _ in resetTestState() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Base URL")
                    endpointField(text: $baseURL, prompt: baseURLPlaceholder)
                        .onChange(of: baseURL) { _ in resetTestState() }
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("API Key")
                    endpointSecureField(text: $apiKeyInput, prompt: "sk-...")
                        // env 密钥优先级最高且不可在此覆盖，禁用输入避免误导
                        .disabled(statusModel.keySource == .environment)
                        .onChange(of: apiKeyInput) { _ in resetTestState() }
                    Text(keyHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Model")
                    endpointField(text: $model, prompt: modelPlaceholder)
                        .onChange(of: model) { _ in resetTestState() }
                    if !suggestedModels.isEmpty {
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
                        Button("清除已存密钥") { clearKey() }
                            // env 密钥清不掉（进程环境只读）；无已存密钥时无事可做
                            .disabled(statusModel.maskedKey == nil || statusModel.keySource == .environment)
                        Button("保存") { save() }
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
        }
        .formStyle(.grouped)
        .onAppear {
            if !loaded { loadCurrentConfig() }
            statusModel.refresh()
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

    private var suggestedModels: [String] {
        ProviderPresets.all.first { $0.id == presetID }?.suggestedModels ?? []
    }

    /// 占位符随协议切换，避免 Anthropic 协议下还提示 deepseek 的端点/模型名
    private var baseURLPlaceholder: String {
        apiProtocol == .anthropic ? "https://api.anthropic.com" : "https://api.deepseek.com"
    }

    private var modelPlaceholder: String {
        apiProtocol == .anthropic ? "如 claude-haiku-4-5 / claude-sonnet-4-5" : "如 deepseek-chat / qwen-plus"
    }

    /// 密钥来源提示：掩码回显 + 来源说明；密钥永不以明文出现在 UI
    private var keyHint: String {
        switch statusModel.keySource {
        case .environment:
            return "密钥已由环境变量 / .env 提供（\(statusModel.maskedKey ?? "")），优先生效"
        case .keychain:
            return "已保存：\(statusModel.maskedKey ?? "")（钥匙串）；留空保存表示保持不变"
        case .legacyUserDefaults:
            return "已保存：\(statusModel.maskedKey ?? "")（本地存储，钥匙串不可用已回退）；建议重新输入保存一次"
        case .none:
            // 免密钥预设（Ollama 本地等）：空密钥是合法配置，不再是「回落系统词典」
            if ProviderPresets.all.first(where: { $0.id == presetID })?.apiKeyOptional == true {
                return "该供应商无需密钥；填好 Base URL 与 Model 即可直接使用"
            }
            return "未配置密钥；全部留空则使用 macOS 系统词典兜底"
        }
    }

    private func loadCurrentConfig() {
        let config = AppConfig.shared
        baseURL = config.baseURL
        model = config.model
        apiProtocol = config.apiProtocol
        presetID = ProviderPresets.matching(baseURL: config.baseURL)?.id ?? ProviderPresets.customID
        // 密钥不回显明文：已有密钥经掩码提示展示，输入框留空 = 保持不变
        apiKeyInput = ""
        loaded = true
    }

    private func applyPreset(_ id: String) {
        resetTestState()
        notice = nil
        guard let preset = ProviderPresets.all.first(where: { $0.id == id }),
              preset.id != ProviderPresets.customID else { return }
        baseURL = preset.baseURL
        apiProtocol = preset.apiProtocol
        if !preset.suggestedModels.contains(model) {
            model = preset.suggestedModels.first ?? model
        }
    }

    /// 用表单当前值测试（而非已保存值），保存前即可发现问题；密钥留空自动代入生效密钥
    private func runTest() {
        testGeneration += 1
        let generation = testGeneration
        testState = .testing
        notice = nil
        Task { @MainActor in
            let result = await LLMConnectionTester().test(
                baseURL: baseURL,
                apiKey: apiKeyInput.trimmingCharacters(in: .whitespaces),
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

    /// 表单变动后作废进行中的测试结果，并清空内联结果区
    private func resetTestState() {
        testGeneration += 1
        testState = .idle
    }

    private func save() {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        guard trimmedURL.isEmpty || trimmedURL.hasPrefix("http://") || trimmedURL.hasPrefix("https://") else {
            notice = "❌ Base URL 需以 http:// 或 https:// 开头，未保存"
            return
        }
        let config = AppConfig.shared
        config.baseURL = trimmedURL
        config.model = trimmedModel
        config.apiProtocol = apiProtocol
        let keyInput = apiKeyInput.trimmingCharacters(in: .whitespaces)
        if !keyInput.isEmpty {
            config.setAPIKey(keyInput) // 优先钥匙串，失败内部自动回退本地存储
        }
        // 密钥留空 = 保持已存密钥不变（清除走专门按钮，避免误清）
        apiKeyInput = ""
        notice = config.apiKeySource == .legacyUserDefaults
            ? "✅ 已保存并立即生效（钥匙串不可用，密钥回退本地存储）"
            : "✅ 已保存并立即生效"
        statusModel.refresh()
    }

    private func clearKey() {
        let wasEnvironment = statusModel.keySource == .environment
        let keychainCleared = AppConfig.shared.setAPIKey("") // 钥匙串与 UserDefaults 同时清除
        statusModel.refresh()
        if wasEnvironment {
            notice = "已清除本地密钥；环境变量 / .env 的密钥仍生效"
        } else if !keychainCleared || AppConfig.shared.apiKeySource == .keychain {
            // 删除失败时旧密钥仍会生效，不能报「已清除」蒙混过关
            notice = "⚠️ 钥匙串删除失败，密钥可能仍生效，请稍后重试"
        } else {
            notice = "已清除已存密钥"
        }
    }
}
