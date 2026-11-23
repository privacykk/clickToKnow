import Foundation

/// 应用配置，UserDefaults 持久化（线程安全，无需主线程隔离）。
/// 密钥读取优先级：环境变量（含 .env 注入）→ 钥匙串 → UserDefaults（遗留明文）。
final class AppConfig {
    static let shared = AppConfig()

    /// 快捷键绑定持久化后广播；AppDelegate 监听以刷新状态、菜单栏展示最新绑定
    static let hotKeyBindingChangedNotification = Notification.Name("ctkHotKeyBindingChanged")

    private let defaults: UserDefaults

    private init() {
        // 显式 suite，配置固定写入 ~/Library/Preferences/ClickToKnow.plist，
        // 不受裸可执行文件缺少 bundle 的影响，也便于 `defaults write ClickToKnow ...` 直接写入。
        defaults = UserDefaults(suiteName: "ClickToKnow") ?? .standard
    }

    /// 注入 UserDefaults 的初始化入口，仅供单元测试使用（独立 suite 防污染真实配置）
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Key {
        static let apiKey = "apiKey" // 遗留明文密钥：只读兼容与迁移，不再新增写入
        static let baseURL = "baseURL" // 遗留单配置端点：迁移后即移除，不再读写
        static let model = "model" // 同上
        static let apiProtocol = "apiProtocol" // 同上
        static let apiProfiles = "apiProfiles"
        static let activeProfileID = "activeProfileID"
        static let hotKeyKeyCode = "hotKeyKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let blacklistedBundleIDs = "blacklistedBundleIDs"
    }

    /// 密钥当前生效来源，用于状态页/设置页展示
    enum APIKeySource: String {
        case environment         // 环境变量 / .env（EnvLoader 注入 env 后两者不可分辨，UI 文案合并展示）
        case keychain
        case legacyUserDefaults  // 迁移未成功的遗留明文（钥匙串不可用时的回退）
        case none
    }

    // MARK: - 已配置的 API（多配置）

    /// 已保存的 API 配置列表（JSON 持久化）。密钥不在其中：按 profile id 分 account 存钥匙串。
    var apiProfiles: [APIProfile] {
        get {
            guard let data = defaults.data(forKey: Key.apiProfiles) else { return [] }
            return (try? JSONDecoder().decode([APIProfile].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.apiProfiles) }
    }

    /// 当前生效配置的 id（无选中/未设置时为 nil，activeProfile 会回退列表首项）
    var activeProfileID: UUID? {
        get { defaults.string(forKey: Key.activeProfileID).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.activeProfileID) }
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
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        apiProfiles = profiles
        return profile
    }

    /// 删除配置并清理其钥匙串密钥；激活项被删时切到剩余第一项（无剩余则回到系统词典兜底）
    func deleteProfile(id: UUID) {
        apiProfiles = apiProfiles.filter { $0.id != id }
        KeychainSecretStore.delete(account: Self.keychainAccount(for: id))
        if activeProfileID == id {
            activeProfileID = apiProfiles.first?.id
        }
    }

    /// 按生效 profile 生成钥匙串 account（"profile-<uuid>"），实现密钥按配置隔离
    static func keychainAccount(for profileID: UUID) -> String {
        "profile-\(profileID.uuidString)"
    }

    /// 指定配置实际生效的密钥（环境变量 → 该配置的钥匙串 → 仅生效配置可退遗留链）。
    /// 供设置页「测试连接 / 拉取模型」对非生效配置也能取到正确密钥。
    func effectiveAPIKey(for profile: APIProfile?) -> String {
        if apiKeyFromEnvironment {
            return ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? ""
        }
        guard let profile else { return "" }
        if let key = KeychainSecretStore.load(account: Self.keychainAccount(for: profile.id)),
           !key.isEmpty { return key }
        if activeProfile?.id == profile.id {
            if let key = KeychainSecretStore.load(), !key.isEmpty { return key }
            return defaults.string(forKey: Key.apiKey) ?? ""
        }
        return ""
    }

    /// 指定配置的已存密钥掩码。legacy 链（默认 account / UserDefaults 明文）只可能属于
    /// 当前生效配置（单配置时代的遗留），非生效配置不回退到它，避免误导性回显。
    func storedKeyMask(for profile: APIProfile) -> (masked: String, legacy: Bool)? {
        if let key = KeychainSecretStore.load(account: Self.keychainAccount(for: profile.id)), !key.isEmpty {
            return (Self.mask(key), false)
        }
        if activeProfile?.id == profile.id {
            if let key = KeychainSecretStore.load(), !key.isEmpty { return (Self.mask(key), false) }
            if let key = defaults.string(forKey: Key.apiKey), !key.isEmpty { return (Self.mask(key), true) }
        }
        return nil
    }

    /// 清除指定配置的密钥（含其作为生效配置时的遗留存储）。返回是否确认清除成功。
    @discardableResult
    func clearAPIKey(for profile: APIProfile) -> Bool {
        var succeeded = KeychainSecretStore.delete(account: Self.keychainAccount(for: profile.id))
        if activeProfile?.id == profile.id {
            succeeded = KeychainSecretStore.delete() && succeeded
            defaults.removeObject(forKey: Key.apiKey)
        }
        return succeeded
    }

    // MARK: - 生效配置的只读视图（ProviderFactory / 状态页 / 测试器共用）

    /// 密钥优先从环境变量读取，避免写进代码/仓库；其次按生效配置查钥匙串，再退遗留存储
    var apiKey: String {
        if apiKeyFromEnvironment {
            return ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? ""
        }
        if let profile = activeProfile,
           let keychain = KeychainSecretStore.load(account: Self.keychainAccount(for: profile.id)),
           !keychain.isEmpty {
            return keychain
        }
        if let keychain = KeychainSecretStore.load(), !keychain.isEmpty {
            return keychain
        }
        return defaults.string(forKey: Key.apiKey) ?? ""
    }

    /// 生效配置的端点/模型/协议只读视图（无配置时给安全默认值，不抛错）
    var baseURL: String { activeProfile?.baseURL ?? "" }
    var model: String { activeProfile?.model ?? "" }
    var apiProtocol: APIProtocol { activeProfile?.apiProtocol ?? .openAICompatible }

    /// 密钥是否由环境变量/.env 提供（true 时设置窗口无需回显，保存留空也不会禁用 LLM）
    var apiKeyFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? "").isEmpty
    }

    /// 判定密钥实际来源，顺序同 apiKey 读取链（环境 → 钥匙串 → 遗留明文 → 无）
    var apiKeySource: APIKeySource {
        if apiKeyFromEnvironment { return .environment }
        if let profile = activeProfile,
           let keychain = KeychainSecretStore.load(account: Self.keychainAccount(for: profile.id)),
           !keychain.isEmpty { return .keychain }
        if let keychain = KeychainSecretStore.load(), !keychain.isEmpty { return .keychain }
        if let legacy = defaults.string(forKey: Key.apiKey), !legacy.isEmpty { return .legacyUserDefaults }
        return .none
    }

    /// LLM 是否可用：Base URL 与 Model 必填；密钥非空即可用，
    /// 密钥为空时仅当 Base URL 命中「密钥可选」预设（如 Ollama 本地）才视为可用，
    /// 否则静默回落系统词典会让「Ollama 免密钥」名存实亡。
    var hasLLMConfig: Bool {
        Self.isLLMReady(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    /// 纯函数版判定，供单元测试（apiKey 读取链涉及环境变量/钥匙串，不便于测试隔离）
    static func isLLMReady(baseURL: String, apiKey: String, model: String) -> Bool {
        guard !baseURL.isEmpty, !model.isEmpty else { return false }
        if !apiKey.isEmpty { return true }
        return ProviderPresets.matching(baseURL: baseURL)?.apiKeyOptional ?? false
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

    /// 为生效配置写入或清除密钥：优先钥匙串，失败回退 UserDefaults（裸可执行 ad-hoc 签名场景保底）。
    /// 传空串 = 同时清除两处存储（环境变量来源的密钥不受影响，仍生效）。
    /// 返回值：true = 钥匙串操作成功（或非空密钥已安全落钥匙串）；false = 回退/删除失败，
    /// 调用方应据此如实提示，避免「已清除」但旧密钥仍在钥匙串里复活。
    @discardableResult
    func setAPIKey(_ value: String) -> Bool {
        let account = activeProfile.map { Self.keychainAccount(for: $0.id) } ?? "apiKey"
        if value.isEmpty {
            let profileDeleted = KeychainSecretStore.delete(account: account)
            // 默认 account 与明文属于同一生效配置（单配置时代遗留），一并清除避免旧值复活
            let legacyDeleted = KeychainSecretStore.delete()
            defaults.removeObject(forKey: Key.apiKey)
            return profileDeleted && legacyDeleted
        }
        if KeychainSecretStore.save(value, account: account) {
            defaults.removeObject(forKey: Key.apiKey) // 同步移除遗留明文，保持单一事实来源
            return true
        }
        defaults.set(value, forKey: Key.apiKey)
        return false
    }

    /// 一次性迁移（幂等），启动时调用：
    /// 1. 单配置时代的端点三件套（baseURL/model/apiProtocol）→ 首个 APIProfile 并置为生效，
    ///    旧默认 account 的钥匙串密钥随迁到 profile account；
    /// 2. UserDefaults 遗留明文密钥 → 钥匙串；钥匙串已有值时以其为准直接删明文。
    /// 迁移失败保持原状（读取链仍会兜底），下次启动重试。
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
                if let legacyKey = KeychainSecretStore.load(), !legacyKey.isEmpty,
                   KeychainSecretStore.save(legacyKey, account: Self.keychainAccount(for: profile.id)) {
                    KeychainSecretStore.delete()
                }
                apiProfiles = [profile]
                activeProfileID = profile.id
                Log.config.info("单配置已迁移为 API 配置列表（1 项）")
            }
            // 端点三键无论是否建出 profile 都不再读写（profile 已成为唯一事实来源）
            defaults.removeObject(forKey: Key.baseURL)
            defaults.removeObject(forKey: Key.model)
            defaults.removeObject(forKey: Key.apiProtocol)
        }
        migrateLegacyKeyIfNeeded()
    }

    /// 遗留明文密钥迁移：钥匙串该 account 已有值则直接删明文；否则迁入成功后再删明文
    private func migrateLegacyKeyIfNeeded() {
        guard let legacy = defaults.string(forKey: Key.apiKey), !legacy.isEmpty else { return }
        let account = activeProfile.map { Self.keychainAccount(for: $0.id) } ?? "apiKey"
        if let existing = KeychainSecretStore.load(account: account), !existing.isEmpty {
            defaults.removeObject(forKey: Key.apiKey)
            Log.config.info("钥匙串已有密钥，已移除 UserDefaults 遗留明文")
        } else if KeychainSecretStore.save(legacy, account: account) {
            defaults.removeObject(forKey: Key.apiKey)
            Log.config.info("已将遗留明文密钥迁移至钥匙串")
        }
    }

    // MARK: - 应用黑名单

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
        let user = defaults.stringArray(forKey: Key.blacklistedBundleIDs) ?? []
        return Self.builtInBlacklistedBundleIDs.union(user)
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
