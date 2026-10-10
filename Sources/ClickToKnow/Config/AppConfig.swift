import Foundation

/// 应用配置，UserDefaults 持久化（线程安全，无需主线程隔离）。
final class AppConfig {
    static let shared = AppConfig()

    private let defaults: UserDefaults

    private init() {
        // 显式 suite，配置固定写入 ~/Library/Preferences/ClickToKnow.plist，
        // 不受裸可执行文件缺少 bundle 的影响，也便于 `defaults write ClickToKnow ...` 直接写入。
        defaults = UserDefaults(suiteName: "ClickToKnow") ?? .standard
    }

    private enum Key {
        static let apiKey = "apiKey"
        static let baseURL = "baseURL"
        static let model = "model"
    }

    var apiKey: String {
        get {
            // 密钥优先从环境变量读取，避免写进代码/仓库
            if let env = ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"],
               !env.isEmpty {
                return env
            }
            return defaults.string(forKey: Key.apiKey) ?? ""
        }
        set { defaults.set(newValue, forKey: Key.apiKey) }
    }

    var baseURL: String {
        get { defaults.string(forKey: Key.baseURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.baseURL) }
    }

    var model: String {
        get { defaults.string(forKey: Key.model) ?? "" }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    /// 密钥是否由环境变量/.env 提供（true 时设置窗口无需回显，保存留空也不会禁用 LLM）
    var apiKeyFromEnvironment: Bool {
        !(ProcessInfo.processInfo.environment["CLICKTOKNOW_API_KEY"] ?? "").isEmpty
    }

    var hasLLMConfig: Bool {
        !apiKey.isEmpty && !baseURL.isEmpty && !model.isEmpty
    }
}