import Foundation

/// 按协议拉取供应商的模型目录（供设置页「拉取模型」选择）。
/// 四个协议的列表接口都是 GET，差异在路径、鉴权头与响应结构。
struct ModelCatalogFetcher {
    private let session: URLSession

    /// session 可注入，便于测试替换为本地 stub
    init(session: URLSession = LLMProviderSupport.makeSession()) {
        self.session = session
    }

    /// 返回去重并按字典序排序的模型 ID 列表；失败抛 InterpretationError（文案与连接测试同口径）
    func fetch(baseURL: String, apiKey: String, apiProtocol: APIProtocol) async throws -> [String] {
        // apiKey 不走 LLMEndpointConfig，单独清洗：换行混入会让 CFNetwork 静默丢弃鉴权头
        let apiKey = LLMProviderSupport.sanitizedAPIKey(apiKey)
        let base = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.hasPrefix("http://") || base.hasPrefix("https://") else {
            throw InterpretationError.badConfiguration
        }

        var request = URLRequest(url: endpoint(base: base, apiProtocol: apiProtocol))
        request.httpMethod = "GET"
        request.timeoutInterval = 15 // 目录拉取不应久等
        switch apiProtocol {
        case .openAICompatible, .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini:
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw InterpretationError.server(LLMProviderSupport.networkHint(urlError, timeoutSeconds: 15))
        }
        guard let http = response as? HTTPURLResponse else {
            throw InterpretationError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw LLMProviderSupport.serverError(status: http.statusCode, data: data)
        }
        return try parse(data: data, apiProtocol: apiProtocol)
    }

    /// 各协议的模型列表端点（差异只在 Anthropic 需补 /v1 前缀）
    private func endpoint(base: String, apiProtocol: APIProtocol) -> URL {
        switch apiProtocol {
        // Anthropic 的 baseURL 不带 /v1（与 Messages 的拼接口径一致），其余 baseURL 自带版本段
        case .anthropic: return URL(string: base + "/v1/models")!
        case .openAICompatible, .openAIResponses, .gemini: return URL(string: base + "/models")!
        }
    }

    /// 按协议解析响应并归一化（去重 + 字典序排序）
    private func parse(data: Data, apiProtocol: APIProtocol) throws -> [String] {
        let ids: [String]
        switch apiProtocol {
        case .openAICompatible, .openAIResponses, .anthropic:
            // OpenAI 与 Anthropic 同为 {"data":[{"id":...}]}
            let decoded = try decode(IDList.self, from: data)
            ids = decoded.data.map(\.id)
        case .gemini:
            // {"models":[{"name":"models/gemini-2.5-flash","supportedGenerationMethods":[...]}]}
            // 只保留支持 generateContent 的模型（嵌入/排序等模型无法用于释义），并去掉 models/ 前缀
            let decoded = try decode(GeminiModelList.self, from: data)
            ids = decoded.models
                .filter { $0.supportedGenerationMethods?.contains("generateContent") ?? true }
                .map { $0.name.hasPrefix("models/") ? String($0.name.dropFirst(7)) : $0.name }
        }
        return Array(Set(ids.filter { !$0.isEmpty })).sorted()
    }

    /// JSON 解码：失败统一归为 badResponse
    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw InterpretationError.badResponse
        }
    }

    /// OpenAI/Anthropic 共用的模型列表响应：{"data":[{"id":...}]}
    private struct IDList: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    /// Gemini 模型列表响应：models[].name 形如 "models/gemini-2.5-flash"
    private struct GeminiModelList: Decodable {
        struct Entry: Decodable {
            let name: String
            let supportedGenerationMethods: [String]?
        }
        let models: [Entry]
    }
}
