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
        static let baseURL = "baseURL"
        static let model = "model"
        static let apiProtocol = "apiProtocol"
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

    var apiKey: String {
        get {
            // 密钥优先从环境变量读取，避免写进代码/仓库
            if apiKeyFromEnvironment {
                return ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? ""
            }
            if let keychain = KeychainSecretStore.load(), !keychain.isEmpty {
                return keychain
            }
            return defaults.string(forKey: Key.apiKey) ?? ""
        }
        set { setAPIKey(newValue) }
    }

    var baseURL: String {
        get { defaults.string(forKey: Key.baseURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.baseURL) }
    }

    var model: String {
        get { defaults.string(forKey: Key.model) ?? "" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    /// API 协议（OpenAI 兼容 / Anthropic）；老配置无此键，回退 OpenAI 兼容，行为与升级前一致
    var apiProtocol: APIProtocol {
        get {
            guard let raw = defaults.string(forKey: Key.apiProtocol) else { return .openAICompatible }
            return APIProtocol(rawValue: raw) ?? .openAICompatible
        }
        set { defaults.set(newValue.rawValue, forKey: Key.apiProtocol) }
    }

    /// 密钥是否由环境变量/.env 提供（true 时设置窗口无需回显，保存留空也不会禁用 LLM）
    var apiKeyFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? "").isEmpty
    }

    var apiKeySource: APIKeySource {
        if apiKeyFromEnvironment { return .environment }
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

    /// 掩码密钥（前4后4，如 sk-a••••3456）；未配置密钥时为 nil。UI/日志一律不回显完整密钥。
    var maskedAPIKey: String? {
        let key = apiKey
        guard !key.isEmpty else { return nil }
        return Self.mask(key)
    }

    static func mask(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        return "\(key.prefix(4))••••\(key.suffix(4))"
    }

    /// 写入或清除密钥：优先钥匙串，失败回退 UserDefaults（裸可执行 ad-hoc 签名场景保底）。
    /// 传空串 = 同时清除两处存储（环境变量来源的密钥不受影响，仍生效）。
    /// 返回值：true = 钥匙串操作成功（或非空密钥已安全落钥匙串）；false = 回退/删除失败，
    /// 调用方应据此如实提示，避免「已清除」但旧密钥仍在钥匙串里复活。
    @discardableResult
    func setAPIKey(_ value: String) -> Bool {
        if value.isEmpty {
            let keychainDeleted = KeychainSecretStore.delete()
            defaults.removeObject(forKey: Key.apiKey)
            return keychainDeleted
        }
        if KeychainSecretStore.save(value) {
            defaults.removeObject(forKey: Key.apiKey) // 同步移除遗留明文，保持单一事实来源
            return true
        }
        defaults.set(value, forKey: Key.apiKey)
        return false
    }

    /// 一次性迁移（幂等）：UserDefaults 遗留明文 → 钥匙串；钥匙串已有值时以其为准直接删明文。
    /// 迁移失败保持原状（读取链仍会兜底到 UserDefaults），下次启动重试。
    func migrateLegacyKeyIfNeeded() {
        guard let legacy = defaults.string(forKey: Key.apiKey), !legacy.isEmpty else { return }
        if let existing = KeychainSecretStore.load(), !existing.isEmpty {
            defaults.removeObject(forKey: Key.apiKey)
            Log.config.info("钥匙串已有密钥，已移除 UserDefaults 遗留明文")
        } else if KeychainSecretStore.save(legacy) {
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
