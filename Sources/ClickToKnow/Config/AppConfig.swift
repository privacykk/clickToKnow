import Foundation

/// 应用配置，UserDefaults 持久化（线程安全，无需主线程隔离）。
/// 密钥读取优先级：环境变量（含 .env 注入）→ 钥匙串 → UserDefaults（遗留明文）。
final class AppConfig {
    static let shared = AppConfig()

    /// 快捷键绑定持久化后广播；AppDelegate 监听以刷新状态、菜单栏展示最新绑定
    static let hotKeyBindingChangedNotification = Notification.Name("ctkHotKeyBindingChanged")

    /// LLM 配置（配置列表 / 生效项 / 密钥）变更后广播；
    /// AppStatusModel 监听后立即刷新，保证「大模型」与「状态总览」两页永远同一口径
    static let llmConfigChangedNotification = Notification.Name("ctkLLMConfigChanged")

    private let defaults: UserDefaults
    /// 密钥存储（生产 = 钥匙串）；单测注入可失败实现以覆盖回退与隔离路径
    private let secrets: any SecretStoring

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
    }

    /// 单配置时代遗留的钥匙串 account（无 owner 归属时的历史存储位）
    static let legacyKeychainAccount = "apiKey"

    /// 密钥当前生效来源，用于状态页/设置页展示
    enum APIKeySource: String {
        case environment         // 环境变量 / .env（EnvLoader 注入 env 后两者不可分辨，UI 文案合并展示）
        case keychain
        case legacyUserDefaults  // 迁移未成功的遗留明文（钥匙串不可用时的回退）
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
        if isFirstProfile, legacyKeyOwnerID == nil, let value = loadLegacyKeyValue() {
            legacyKeyOwnerID = profile.id
            adoptLegacyKey(value, into: profile.id)
        }
        return profile
    }

    /// 删除配置并清理其钥匙串密钥；激活项被删时切到剩余第一项（无剩余则回到系统词典兜底）
    func deleteProfile(id: UUID) {
        apiProfiles = apiProfiles.filter { $0.id != id }
        secrets.delete(account: Self.keychainAccount(for: id))
        // 遗留存储若归属该配置，必须一并清除：否则这份密钥会变成无主值，
        // 被下一个生效配置继承（正是「A 的密钥串到 B」的路径之一）
        if legacyKeyApplies(to: id) {
            clearLegacyKeyStorage()
        }
        if activeProfileID == id {
            activeProfileID = apiProfiles.first?.id
        }
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
    /// 这样「钥匙串不可用 → 回退明文 → 切换生效配置」不会把 A 的密钥交给 B。
    private func legacyKeyApplies(to profileID: UUID?) -> Bool {
        guard let profileID, let owner = legacyKeyOwnerID else { return false }
        return owner == profileID
    }

    /// 读取遗留全局密钥（调用方须先用 legacyKeyApplies 校验归属）
    private func loadLegacyKeyValue() -> String? {
        if let key = secrets.load(account: Self.legacyKeychainAccount), !key.isEmpty { return key }
        let plaintext = defaults.string(forKey: Key.apiKey) ?? ""
        return plaintext.isEmpty ? nil : plaintext
    }

    /// 清空遗留全局存储（明文 + 默认钥匙串 account + 归属记录）
    @discardableResult
    private func clearLegacyKeyStorage() -> Bool {
        defaults.removeObject(forKey: Key.apiKey)
        let keychainCleared = secrets.delete(account: Self.legacyKeychainAccount)
        // 钥匙串删不掉时保留归属记录：遗留值仍在，但只能被原归属配置读到
        if keychainCleared { legacyKeyOwnerID = nil }
        return keychainCleared
    }

    /// 指定配置实际生效的密钥：环境变量 → 该配置自己的钥匙串 → 仅当遗留存储归属它时才回退。
    /// 供设置页「测试连接 / 拉取模型」对非生效配置也能取到正确密钥。
    func effectiveAPIKey(for profile: APIProfile?) -> String {
        if apiKeyFromEnvironment {
            return ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? ""
        }
        guard let profile else { return "" }
        if let key = secrets.load(account: Self.keychainAccount(for: profile.id)),
           !key.isEmpty { return key }
        guard legacyKeyApplies(to: profile.id) else { return "" }
        return loadLegacyKeyValue() ?? ""
    }

    /// 指定配置的已存密钥掩码。legacy 链（默认 account / UserDefaults 明文）只对
    /// 归属该配置时回显，否则会出现「B 显示着 A 的掩码」的误导。
    func storedKeyMask(for profile: APIProfile) -> (masked: String, legacy: Bool)? {
        if let key = secrets.load(account: Self.keychainAccount(for: profile.id)), !key.isEmpty {
            return (Self.mask(key), false)
        }
        guard legacyKeyApplies(to: profile.id) else { return nil }
        if let key = secrets.load(account: Self.legacyKeychainAccount), !key.isEmpty {
            return (Self.mask(key), false)
        }
        if let key = defaults.string(forKey: Key.apiKey), !key.isEmpty { return (Self.mask(key), true) }
        return nil
    }

    /// 清除指定配置的密钥（含归属它的遗留存储）。返回是否确认清除成功。
    @discardableResult
    func clearAPIKey(for profile: APIProfile) -> Bool {
        var succeeded = secrets.delete(account: Self.keychainAccount(for: profile.id))
        if legacyKeyApplies(to: profile.id) {
            succeeded = clearLegacyKeyStorage() && succeeded
        }
        notifyLLMConfigChanged()
        return succeeded
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
        if let key = secrets.load(account: Self.keychainAccount(for: profile.id)), !key.isEmpty {
            return .keychain
        }
        guard legacyKeyApplies(to: profile.id) else { return .none }
        if let key = secrets.load(account: Self.legacyKeychainAccount), !key.isEmpty { return .keychain }
        if let legacy = defaults.string(forKey: Key.apiKey), !legacy.isEmpty { return .legacyUserDefaults }
        return .none
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

    /// 为生效配置写入或清除密钥：优先钥匙串，失败回退 UserDefaults（裸可执行 ad-hoc 签名场景保底）。
    /// 传空串 = 清除该配置的密钥存储（环境变量来源的密钥不受影响，仍生效）。
    /// 返回值：true = 钥匙串操作成功（或非空密钥已安全落钥匙串）；false = 回退/删除失败，
    /// 调用方应据此如实提示，避免「已清除」但旧密钥仍在钥匙串里复活。
    @discardableResult
    func setAPIKey(_ value: String) -> Bool {
        guard let profile = activeProfile else {
            // 没有生效配置时无处归属：不写全局明文（否则会被下个新建配置继承）
            if !value.isEmpty {
                Log.config.warning("尚无生效 API 配置，密钥未保存")
                return false
            }
            clearLegacyKeyStorage()
            return true
        }
        return setAPIKey(value, for: profile)
    }

    /// 为指定配置写入密钥（编辑非生效配置时用，避免误写到当前生效项）。
    /// 钥匙串写入失败时回退到的本地明文会记录归属该配置，因此非生效配置也能安全回退；
    /// 但仍返回 false，由 UI 如实提示「已回退本地存储」。
    @discardableResult
    func setAPIKey(_ value: String, for profile: APIProfile) -> Bool {
        guard !value.isEmpty else { return clearAPIKey(for: profile) }
        if secrets.save(value, account: Self.keychainAccount(for: profile.id)) {
            // 新密钥已落该配置自己的条目：归属它的遗留值（若有）视为被取代，清掉避免旧值复活
            if legacyKeyApplies(to: profile.id) { clearLegacyKeyStorage() }
            notifyLLMConfigChanged()
            return true
        }
        // 钥匙串不可用：回退到带归属的本地明文。归属记录是本函数安全性的全部前提——
        // 没有它，这份明文会被下一个生效配置读走。
        defaults.set(value, forKey: Key.apiKey)
        legacyKeyOwnerID = profile.id
        Log.config.warning("钥匙串写入失败，密钥已回退本地存储并绑定归属配置 \(profile.id.uuidString.prefix(8))")
        notifyLLMConfigChanged()
        return false
    }

    /// 一次性迁移（幂等），启动时调用：
    /// 1. 单配置时代的端点三件套（baseURL/model/apiProtocol）→ 首个 APIProfile 并置为生效，
    ///    旧默认 account 的钥匙串密钥随迁到 profile account；
    /// 2. 遗留密钥（默认钥匙串 account / UserDefaults 明文）→ 归属配置自己的钥匙串条目。
    /// 归属规则是这里的关键：遗留存储只能归给「迁移时确定的那个配置」，否则切换生效配置后
    /// 会跟着串到新配置上。迁移失败保持原状并保留归属记录，下次启动重试。
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
        migrateLegacyKeyIfNeeded()
    }

    /// 遗留密钥迁移 + 归属确定：
    /// - 已记录归属：只迁给归属配置；归属配置已被删除则丢弃遗留值（不跟随新的生效项）。
    /// - 未记录归属（升级自无 owner 的旧版本）：归给当前生效配置，仅此一次。
    /// - 没有生效配置：保留原状，等建出第一个配置时再归属（见 upsertProfile）。
    private func migrateLegacyKeyIfNeeded() {
        guard let legacyValue = loadLegacyKeyValue() else { return }

        if let owner = legacyKeyOwnerID {
            guard apiProfiles.contains(where: { $0.id == owner }) else {
                clearLegacyKeyStorage()
                Log.config.warning("遗留密钥的归属配置已不存在，已丢弃遗留密钥")
                return
            }
            adoptLegacyKey(legacyValue, into: owner)
            return
        }

        guard let owner = activeProfile?.id else { return }
        legacyKeyOwnerID = owner
        adoptLegacyKey(legacyValue, into: owner)
    }

    /// 把遗留值写进 owner 自己的钥匙串条目，成功后清空遗留存储
    private func adoptLegacyKey(_ value: String, into owner: UUID) {
        let account = Self.keychainAccount(for: owner)
        if let existing = secrets.load(account: account), !existing.isEmpty {
            // 该配置已有自己的密钥：遗留值作废（配置自身条目优先级更高）
            clearLegacyKeyStorage()
            Log.config.info("配置 \(owner.uuidString.prefix(8)) 已有密钥，已清理归属它的遗留存储")
            return
        }
        if secrets.save(value, account: account) {
            clearLegacyKeyStorage()
            Log.config.info("已将遗留密钥迁移至配置 \(owner.uuidString.prefix(8)) 的钥匙串条目")
        }
        // 保存失败：保留遗留存储与归属记录，下次启动重试（归属已绑定，不会串给别的配置）
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
