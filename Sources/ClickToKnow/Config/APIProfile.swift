import Foundation

/// 一套已配置的 LLM API（端点三件套 + 协议）。
/// 密钥不落在此结构：按 profile id 分 account 存钥匙串（见 AppConfig.keychainAccount）。
struct APIProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var apiProtocol: APIProtocol
    var baseURL: String
    var model: String

    init(id: UUID = UUID(), apiProtocol: APIProtocol, baseURL: String, model: String) {
        self.id = id
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.model = model
    }
}
