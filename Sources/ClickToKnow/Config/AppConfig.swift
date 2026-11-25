import Foundation

/// 应用配置，UserDefaults 持久化（线程安全，无需主线程隔离）。
/// 密钥读取优先级：环境变量 → 本次运行 → 钥匙串 → 已归属的遗留明文。
final class AppConfig {
    static let shared = AppConfig()

    /// 快捷键绑定持久化后广播；AppDelegate 监听以刷新状态、菜单栏展示最新绑定
    static let hotKeyBindingChangedNotification = Notification.Name("ctkHotKeyBindingChanged")

    /// LLM 配置（配置列表 / 生效项 / 密钥）变更后广播；
    /// AppStatusModel 监听后立即刷新，保证「大模型」与「状态总览」两页永远同一口径
    static let llmConfigChangedNotification = Notification.Name("ctkLLMConfigChanged")
    static let privacyChangedNotification = Notification.Name("ctkPrivacyChanged")

    private let defaults: UserDefaults
    /// 密钥存储（生产 = 钥匙串）；单测注入可失败实现以覆盖回退与隔离路径
    private let secrets: any SecretStoring
    private let sessionKeyLock = NSLock()
    private var sessionKeys: [UUID: String] = [:]

    private init() {
        // 显式 suite，配置固定写入 ~/Library/Preferences/ClickToKnow.plist，
        // 不受裸可执行文件缺少 bundle 的影响，也便于 `defaults write ClickToKnow ...` 直接写入。
        defaults = UserDefaults(suiteName: "ClickToKnow") ?? .standard
        secrets = KeychainSecrets()
    }

    /// 注入 UserDefaults / 密钥存储的初始化入口，仅供单元测试使用（独立 suite 防污染真实配置）
    init(defaults: UserDefaults, secrets: any SecretStoring = KeychainSecrets()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    private enum Key {
        static let apiKey = "apiKey" // 遗留明文密钥：只读兼容与迁移，不再新增写入
        /// 遗留全局存储（默认钥匙串 account + 上面这条明文）的归属配置。
        /// 单配置时代的这两个存储都没有 owner，切换生效配置后会被新配置直接读到，
        /// 因此写入/迁移时记录归属，读取时只允许归属配置使用。
        static let legacyKeyOwnerProfileID = "legacyAPIKeyOwnerProfileID"
        static let baseURL = "baseURL" // 遗留单配置端点：迁移后即移除，不再读写
        static let model = "model" // 同上
        static let apiProtocol = "apiProtocol" // 同上
        static let apiProfiles = "apiProfiles"
        static let activeProfileID = "activeProfileID"
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let blacklistedBundleIDs = "blacklistedBundleIDs"
        static let localDictionaryOnly = "localDictionaryOnly"
        static let sendsQueryContext = "sendsQueryContext"
        static let recordsQueryHistory = "recordsQueryHistory"
        static let explanationStyle = "explanationStyle"
        static let streamsLLMResults = "streamsLLMResults"
    }

    /// 单配置时代遗留的钥匙串 account（无 owner 归属时的历史存储位）
    static let legacyKeychainAccount = "apiKey"

    /// 密钥当前生效来源，用于状态页/设置页展示
    enum APIKeySource: String {
        case environment         // 环境变量 / .env（EnvLoader 注入 env 后两者不可分辨，UI 文案合并展示）
        case session
        case keychain
        case legacyUserDefaults
        case keychainNeedsAuthorization
        case none
    }

    /// LLM 可用性三态：区分「没配置」与「配置了但还差密钥」，
    /// 避免已保存配置却只显示「未配置」、用户不知道差在哪一步。
    enum LLMStatus: Equatable {
        /// 没有任何 API 配置，或生效配置缺少端点/模型
        case notConfigured
        /// 已有完整配置，但缺少该供应商必需的 API Key（划词会回落系统词典）
        case missingKey
        /// 配置完整，划词走大模型
        case ready
    }

    /// 配置任一要素变更后广播（列表增删、切换生效项、密钥写入/清除都会触发）
    private func notifyLLMConfigChanged() {
        NotificationCenter.default.post(name: Self.llmConfigChangedNotification, object: nil)
    }

    // MARK: - 已配置的 API（多配置）

    /// 已保存的 API 配置列表（JSON 持久化）。密钥不在其中：按 profile id 分 account 存钥匙串。
    var apiProfiles: [APIProfile] {
        get {
            guard let data = defaults.data(forKey: Key.apiProfiles) else { return [] }
            return (try? JSONDecoder().decode([APIProfile].self, from: data)) ?? []
        }
        set {
            defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.apiProfiles)
            notifyLLMConfigChanged()
        }
    }

    /// 当前生效配置的 id（无选中/未设置时为 nil，activeProfile 会回退列表首项）
    var activeProfileID: UUID? {
        get { defaults.string(forKey: Key.activeProfileID).flatMap(UUID.init(uuidString:)) }
        set {
            defaults.set(newValue?.uuidString, forKey: Key.activeProfileID)
            notifyLLMConfigChanged()
        }
    }

    /// 当前生效配置：显式选中优先；选中项被删/数据损坏时回退列表第一项，避免莫名静默失能
    var activeProfile: APIProfile? {
        let profiles = apiProfiles
        if let id = activeProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    /// 新增或更新配置；返回落库后的 profile（保留传入 id 幂等更新，不存在则追加）
    @discardableResult
    func upsertProfile(_ profile: APIProfile) -> APIProfile {
        var profiles = apiProfiles
        let isFirstProfile = profiles.isEmpty
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        apiProfiles = profiles
        // 首个配置出现时收编无主的遗留密钥：此时 owner 唯一可选，不会串给别的配置
        if isFirstProfile { assignLegacyKeyOwnerIfNeeded(to: profile.id) }
        return profile
    }

    enum ProfileSaveResult: Equatable {
        case saved(APIProfile), oldKeyNotCleared, keyNotSaved
    }

    /// 修改端点来源时，保存前确认旧密钥已移除。
    func saveEditedProfile(_ profile: APIProfile, key: String = "", sessionOnly: Bool = false) -> ProfileSaveResult {
        let profiles = apiProfiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }),
           !LLMProviderSupport.sameEndpointHost(profiles[index].baseURL, profile.baseURL) {
            // 新端点使用独立账号，防止写入阶段失败或退出时把新旧密钥发送到对方的端点。
            let replacement = APIProfile(apiProtocol: profile.apiProtocol, baseURL: profile.baseURL, model: profile.model)
            guard prepareAPIKey(key, for: replacement, sessionOnly: sessionOnly) else { return .keyNotSaved }
            guard clearAPIKey(for: profiles[index]) else {
                _ = clearAPIKey(for: replacement)
                return .oldKeyNotCleared
            }
            var updated = profiles
            updated[index] = replacement
            apiProfiles = updated
            if activeProfileID == profile.id { activeProfileID = replacement.id }
            return .saved(replacement)
        }
        guard prepareAPIKey(key, for: profile, sessionOnly: sessionOnly) else { return .keyNotSaved }
        upsertProfile(profile)
        if !key.isEmpty, !sessionOnly { clearSupersededLegacyKey(for: profile) }
        return .saved(profile)
    }

    private func prepareAPIKey(_ key: String, for profile: APIProfile, sessionOnly: Bool) -> Bool {
        guard !key.isEmpty else { return true }
        if sessionOnly {
            sessionKeyLock.withLock { sessionKeys[profile.id] = key }
            return true
        }
        return persistAPIKey(key, for: profile)
    }

    /// 删除配置并清理其钥匙串密钥；激活项被删时切到剩余第一项（无剩余则回到系统词典兜底）
    @discardableResult
    func deleteProfile(id: UUID) -> Bool {
        guard let profile = apiProfiles.first(where: { $0.id == id }), clearAPIKey(for: profile) else {
            return false
        }
        apiProfiles = apiProfiles.filter { $0.id != id }
        if activeProfileID == id {
            activeProfileID = apiProfiles.first?.id
        }
        return true
    }

    /// 按生效 profile 生成钥匙串 account（"profile-<uuid>"），实现密钥按配置隔离
    static func keychainAccount(for profileID: UUID) -> String {
        "profile-\(profileID.uuidString)"
    }

    // MARK: - 遗留密钥归属（单配置时代的全局存储）

    /// 遗留全局密钥当前归属的配置 id
    private var legacyKeyOwnerID: UUID? {
        get { defaults.string(forKey: Key.legacyKeyOwnerProfileID).flatMap(UUID.init(uuidString:)) }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: Key.legacyKeyOwnerProfileID)
            } else {
                defaults.removeObject(forKey: Key.legacyKeyOwnerProfileID)
            }
        }
    }

    /// 遗留全局存储（默认钥匙串 account / UserDefaults 明文）是否属于该配置。
    /// 无 owner 的历史数据一律不认（迁移会在启动或建首个配置时补上 owner），
    /// 切换生效配置时不会把 A 的遗留密钥交给 B。
    private func legacyKeyApplies(to profileID: UUID?) -> Bool {
        guard let profileID, let owner = legacyKeyOwnerID else { return false }
        return owner == profileID
    }

    private func assignLegacyKeyOwnerIfNeeded(to profileID: UUID) {
        guard legacyKeyOwnerID == nil else { return }
        if defaults.string(forKey: Key.apiKey)?.isEmpty == false ||
            secrets.read(account: Self.legacyKeychainAccount, allowInteraction: false) != .missing {
            legacyKeyOwnerID = profileID
        }
    }

    /// 清空遗留全局存储（明文 + 默认钥匙串 account + 归属记录）
    @discardableResult
    private func clearLegacyKeyStorage() -> Bool {
        guard secrets.delete(account: Self.legacyKeychainAccount) else { return false }
        defaults.removeObject(forKey: Key.apiKey)
        legacyKeyOwnerID = nil
        return true
    }

    /// 指定配置实际生效的密钥：环境变量 → 该配置自己的钥匙串 → 仅当遗留存储归属它时才回退。
    /// 供设置页「测试连接 / 拉取模型」对非生效配置也能取到正确密钥。
    func effectiveAPIKey(for profile: APIProfile?) -> String {
        if apiKeyFromEnvironment {
            return ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? ""
        }
        guard let profile else { return "" }
        return storedCredential(for: profile).key
    }

    /// 指定配置的已存密钥掩码。legacy 链（默认 account / UserDefaults 明文）只对
    /// 归属该配置时回显，否则会出现「B 显示着 A 的掩码」的误导。
    func storedKeyMask(for profile: APIProfile) -> String? {
        let key = storedCredential(for: profile).key
        return key.isEmpty ? nil : Self.mask(key)
    }

    func storedKeySource(for profile: APIProfile) -> APIKeySource {
        storedCredential(for: profile).source
    }

    func canMigrateLegacyAPIKey(for profile: APIProfile) -> Bool {
        guard legacyKeyApplies(to: profile.id),
              secrets.read(account: Self.keychainAccount(for: profile.id), allowInteraction: false) == .missing else {
            return false
        }
        let source = storedKeySource(for: profile)
        return source == .legacyUserDefaults || source == .keychain
    }

    private func storedCredential(for profile: APIProfile) -> (key: String, source: APIKeySource) {
        if let key = sessionKeyLock.withLock({ sessionKeys[profile.id] }) { return (key, .session) }
        let account = Self.keychainAccount(for: profile.id)
        switch secrets.read(account: account, allowInteraction: false) {
        case .value(let key): return (key, .keychain)
        case .inaccessible: return ("", .keychainNeedsAuthorization)
        case .missing: break
        }
        guard legacyKeyApplies(to: profile.id) else { return ("", .none) }
        switch secrets.read(account: Self.legacyKeychainAccount, allowInteraction: false) {
        case .value(let key): return (key, .keychain)
        case .inaccessible: return ("", .keychainNeedsAuthorization)
        case .missing:
            if let key = defaults.string(forKey: Key.apiKey), !key.isEmpty {
                return (key, .legacyUserDefaults)
            }
            return ("", .none)
        }
    }

    /// 清除指定配置的密钥（含归属它的遗留存储）。返回是否确认清除成功。
    @discardableResult
    func clearAPIKey(for profile: APIProfile) -> Bool {
        defer { notifyLLMConfigChanged() }
        // 先清旧来源，避免删掉当前条目后旧值重新生效。
        if legacyKeyApplies(to: profile.id), !clearLegacyKeyStorage() { return false }
        guard secrets.delete(account: Self.keychainAccount(for: profile.id)) else { return false }
        _ = sessionKeyLock.withLock { sessionKeys.removeValue(forKey: profile.id) }
        return true
    }

    // MARK: - 生效配置的只读视图（ProviderFactory / 状态页 / 测试器共用）

    /// 生效配置实际生效的密钥（读取链见 effectiveAPIKey(for:)）
    var apiKey: String { effectiveAPIKey(for: activeProfile) }

    /// 生效配置的端点/模型/协议只读视图（无配置时给安全默认值，不抛错）
    var baseURL: String { activeProfile?.baseURL ?? "" }
    var model: String { activeProfile?.model ?? "" }
    var apiProtocol: APIProtocol { activeProfile?.apiProtocol ?? .openAICompatible }

    /// 密钥是否由环境变量/.env 提供（true 时设置窗口无需回显，保存留空也不会禁用 LLM）
    var apiKeyFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? "").isEmpty
    }

    /// 判定密钥实际来源，顺序同 apiKey 读取链（环境 → 该配置钥匙串 → 归属它的遗留存储 → 无）
    var apiKeySource: APIKeySource {
        if apiKeyFromEnvironment { return .environment }
        guard let profile = activeProfile else { return .none }
        return storedKeySource(for: profile)
    }

    /// LLM 是否可用：Base URL 与 Model 必填；密钥非空即可用，
    /// 密钥为空时仅当 Base URL 命中「密钥可选」预设（如 Ollama 本地）才视为可用，
    /// 否则静默回落系统词典会让「Ollama 免密钥」名存实亡。
    var hasLLMConfig: Bool {
        Self.llmStatus(baseURL: baseURL, apiKey: apiKey, model: model) == .ready
    }

    /// 生效配置的细分可用性（状态总览与「大模型」页共用，保证两页口径一致）
    var llmStatus: LLMStatus {
        guard let profile = activeProfile else { return .notConfigured }
        return Self.llmStatus(baseURL: profile.baseURL, apiKey: apiKey, model: profile.model)
    }

    /// 指定配置的可用性：判定规则与生效配置完全一致，列表行据此展示「可用 / 缺少密钥」
    func llmStatus(for profile: APIProfile) -> LLMStatus {
        Self.llmStatus(
            baseURL: profile.baseURL,
            apiKey: effectiveAPIKey(for: profile),
            model: profile.model
        )
    }

    /// 纯函数版判定：先查端点/模型是否齐备，再看密钥（密钥可选预设放行空密钥）
    static func llmStatus(baseURL: String, apiKey: String, model: String) -> LLMStatus {
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        let name = model.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !name.isEmpty else { return .notConfigured }
        if !apiKey.isEmpty { return .ready }
        return ProviderPresets.matching(baseURL: url)?.apiKeyOptional == true ? .ready : .missingKey
    }

    /// 纯函数版判定，供单元测试（apiKey 读取链涉及环境变量/钥匙串，不便于测试隔离）
    static func isLLMReady(baseURL: String, apiKey: String, model: String) -> Bool {
        llmStatus(baseURL: baseURL, apiKey: apiKey, model: model) == .ready
    }

    /// 生效配置的掩码密钥（前4后4，如 sk-a••••3456）；未配置密钥时为 nil。UI/日志一律不回显完整密钥。
    var maskedAPIKey: String? {
        let key = apiKey
        guard !key.isEmpty else { return nil }
        return Self.mask(key)
    }

    /// 掩码规则：长度 > 8 保留前4后4，否则整体打点
    static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(4))••••\(key.suffix(4))"
    }

    /// 为生效配置保存或清除密钥。
    @discardableResult
    func setAPIKey(_ value: String) -> Bool {
        guard let profile = activeProfile else {
            // 没有生效配置时无处归属：不写全局明文（否则会被下个新建配置继承）
            if !value.isEmpty {
                Log.config.warning("尚无生效 API 配置，密钥未保存")
                return false
            }
            return clearLegacyKeyStorage()
        }
        return setAPIKey(value, for: profile)
    }

    /// 保存失败时由用户决定是否仅在本次运行中使用。
    @discardableResult
    func setAPIKey(_ value: String, for profile: APIProfile) -> Bool {
        guard !value.isEmpty else { return clearAPIKey(for: profile) }
        guard persistAPIKey(value, for: profile) else { return false }
        clearSupersededLegacyKey(for: profile)
        notifyLLMConfigChanged()
        return true
    }

    private func persistAPIKey(_ value: String, for profile: APIProfile) -> Bool {
        guard secrets.save(value, account: Self.keychainAccount(for: profile.id)) else { return false }
        _ = sessionKeyLock.withLock { sessionKeys.removeValue(forKey: profile.id) }
        return true
    }

    private func clearSupersededLegacyKey(for profile: APIProfile) {
        if legacyKeyApplies(to: profile.id) {
            defaults.removeObject(forKey: Key.apiKey)
            clearLegacyKeyStorage()
        }
    }

    /// 用户主动授权时重试读取，并在可行时迁移归属该配置的旧密钥。
    @discardableResult
    func authorizeAPIKey(for profile: APIProfile) -> Bool {
        defer { notifyLLMConfigChanged() }
        let account = Self.keychainAccount(for: profile.id)
        switch secrets.read(account: account, allowInteraction: true) {
        case .value: return true
        case .inaccessible: return false
        case .missing: break
        }
        guard legacyKeyApplies(to: profile.id) else { return false }
        let key: String
        switch secrets.read(account: Self.legacyKeychainAccount, allowInteraction: true) {
        case .value(let value): key = value
        case .inaccessible: return false
        case .missing: key = defaults.string(forKey: Key.apiKey) ?? ""
        }
        guard !key.isEmpty else { return false }
        return setAPIKey(key, for: profile)
    }

    /// 启动时迁移旧端点并确定密钥归属。钥匙串写入延后至用户操作。
    func migrateLegacyConfigIfNeeded() {
        if apiProfiles.isEmpty {
            let legacyURL = (defaults.string(forKey: Key.baseURL) ?? "")
                .trimmingCharacters(in: .whitespaces)
            let legacyModel = (defaults.string(forKey: Key.model) ?? "")
                .trimmingCharacters(in: .whitespaces)
            if !legacyURL.isEmpty || !legacyModel.isEmpty {
                let legacyProtocol = defaults.string(forKey: Key.apiProtocol)
                    .flatMap(APIProtocol.init(rawValue:)) ?? .openAICompatible
                let profile = APIProfile(
                    apiProtocol: legacyProtocol, baseURL: legacyURL, model: legacyModel
                )
                apiProfiles = [profile]
                activeProfileID = profile.id
                Log.config.info("单配置已迁移为 API 配置列表（1 项）")
            }
            // 端点三键无论是否建出 profile 都不再读写（profile 已成为唯一事实来源）
            defaults.removeObject(forKey: Key.baseURL)
            defaults.removeObject(forKey: Key.model)
            defaults.removeObject(forKey: Key.apiProtocol)
        }
        if let profile = activeProfile { assignLegacyKeyOwnerIfNeeded(to: profile.id) }
    }

    // MARK: - 应用黑名单

    var explanationStyle: ExplanationStyle {
        get { defaults.string(forKey: Key.explanationStyle).flatMap(ExplanationStyle.init(rawValue:)) ?? .technical }
        set {
            guard newValue != explanationStyle else { return }
            defaults.set(newValue.rawValue, forKey: Key.explanationStyle)
            notifyLLMConfigChanged()
        }
    }

    var streamsLLMResults: Bool {
        get { defaults.object(forKey: Key.streamsLLMResults) as? Bool ?? true }
        set {
            guard newValue != streamsLLMResults else { return }
            defaults.set(newValue, forKey: Key.streamsLLMResults)
            notifyLLMConfigChanged()
        }
    }

    var localDictionaryOnly: Bool {
        get { defaults.bool(forKey: Key.localDictionaryOnly) }
        set { setPrivacyFlag(newValue, forKey: Key.localDictionaryOnly, previous: localDictionaryOnly) }
    }

    var sendsQueryContext: Bool {
        get { defaults.object(forKey: Key.sendsQueryContext) as? Bool ?? true }
        set { setPrivacyFlag(newValue, forKey: Key.sendsQueryContext, previous: sendsQueryContext) }
    }

    var recordsQueryHistory: Bool {
        get { defaults.object(forKey: Key.recordsQueryHistory) as? Bool ?? true }
        set { setPrivacyFlag(newValue, forKey: Key.recordsQueryHistory, previous: recordsQueryHistory) }
    }

    private func setPrivacyFlag(_ value: Bool, forKey key: String, previous: Bool) {
        guard previous != value else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.privacyChangedNotification, object: self)
    }

    /// 内置黑名单：密码/密钥管理类应用永不抓取，选中文本不离开本机、也不进剪贴板
    static let builtInBlacklistedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
    ]

    /// 生效黑名单 = 内置 + 用户追加（`defaults write ClickToKnow blacklistedBundleIDs -array com.xxx.app`）
    var blacklistedBundleIDs: Set<String> {
        Self.builtInBlacklistedBundleIDs.union(customBlacklistedBundleIDs)
    }

    var customBlacklistedBundleIDs: [String] {
        get {
            let ids = defaults.stringArray(forKey: Key.blacklistedBundleIDs) ?? []
            return Self.normalizedBundleIDs(ids)
        }
        set {
            let ids = Self.normalizedBundleIDs(newValue)
            guard ids != customBlacklistedBundleIDs else { return }
            defaults.set(ids, forKey: Key.blacklistedBundleIDs)
            NotificationCenter.default.post(name: Self.privacyChangedNotification, object: self)
        }
    }

    private static func normalizedBundleIDs(_ ids: [String]) -> [String] {
        Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .subtracting(builtInBlacklistedBundleIDs).subtracting([""]).sorted()
    }

    // MARK: - 快捷键

    /// 当前热键绑定；无持久化值时返回默认 ⌥⌘K。
    /// setter 只负责持久化 + 广播；注册是否生效由 SelectionMonitor.reloadHotKey 试注册先行决定，
    /// 因此调用顺序必须是「试注册成功 → 再赋值持久化」。
    var hotKeyBinding: HotKeyBinding {
        get {
            guard defaults.object(forKey: Key.hotKeyKeyCode) != nil else {
                return CarbonKeyTranslator.defaultBinding
            }
            let binding = HotKeyBinding(
                keyCode: UInt32(defaults.integer(forKey: Key.hotKeyKeyCode)),
                carbonModifiers: UInt32(defaults.integer(forKey: Key.hotKeyModifiers))
            )
            // 持久化值可能被手改或损坏；缺 ⌘/⌥/⌃ 的绑定会注册成全局裸键，抢占所有输入
            guard CarbonKeyTranslator.hasRequiredModifier(binding.carbonModifiers) else {
                return CarbonKeyTranslator.defaultBinding
            }
            return binding
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotKeyKeyCode)
            defaults.set(Int(newValue.carbonModifiers), forKey: Key.hotKeyModifiers)
            NotificationCenter.default.post(name: Self.hotKeyBindingChangedNotification, object: newValue)
        }
    }
}
