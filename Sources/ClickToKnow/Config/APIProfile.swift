import Foundation

/// 一套已配置的 LLM API（端点三件套 + 协议）。
/// 密钥不落在此结构：按 profile id 分 account 存钥匙串（见 AppConfig.keychainAccount）。
struct APIProfile: Codable, Equatable, Identifiable {
    /// 唯一标识；同时作为钥匙串 account 的一部分，用于隔离不同 profile 的密钥
    var id: UUID
    /// 该 profile 使用的 API 协议（决定走哪个 Provider 实现）
    var apiProtocol: APIProtocol
    /// API 端点根地址（如 https://api.deepseek.com）
    var baseURL: String
    /// 使用的模型名（如 deepseek-chat）
    var model: String

    /// 默认参数构造：id 缺省时自动生成新 UUID，便于 UI 新建 profile
    init(id: UUID = UUID(), apiProtocol: APIProtocol, baseURL: String, model: String) {
        self.id = id
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.model = model
    }
}
