import Foundation

/// 一次查询开始时的配置快照。
///
/// 存在的理由：`AppConfig.shared` 是可变单例，查询往返期间用户可能切换配置、改模型、删密钥。
/// 若响应回来后才去读它，就会出现「缓存键按旧端点写、历史记录归到新模型」这类错位。
/// 因此在 `handleSelectedText` 入口取一次快照，缓存键、Provider、历史归属全部取自同一份。
struct QuerySnapshot: Equatable {
    /// 发起查询时生效的配置 id（无配置为 nil），用于缓存键的配置指纹
    let profileID: UUID?
    let apiProtocol: APIProtocol
    let baseURL: String
    let model: String
    /// 已清洗的密钥（换行/空白会令 CFNetwork 丢弃 Authorization 头）
    let apiKey: String
    /// 本次查询是否真的走 LLM。缺密钥且供应商要求鉴权时为 false → 回落系统词典
    let usesLLM: Bool
    let explanationStyle: ExplanationStyle
    let streamsResults: Bool
    private let sendsContext: Bool

    /// 本次查询的释义来源，参与缓存键：同一端点在「缺密钥走词典」与「有密钥走 LLM」之间切换时
    /// 内容完全不同，必须分键，否则补上密钥后仍会命中旧的词典结果
    var source: Interpretation.Source { usesLLM ? .llm : .systemDictionary }

    /// 历史记录应归属的模型名；走词典时为 nil（历史里不谎报成某个模型）
    var historyModel: String? { usesLLM ? model : nil }

    init(
        profileID: UUID?, apiProtocol: APIProtocol, baseURL: String, model: String, apiKey: String,
        localDictionaryOnly: Bool = false, sendsContext: Bool = true,
        explanationStyle: ExplanationStyle = .technical, streamsResults: Bool = true
    ) {
        let sanitizedKey = LLMProviderSupport.sanitizedAPIKey(apiKey)
        self.profileID = profileID
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.model = model
        self.apiKey = sanitizedKey
        // 判定规则与 AppConfig.hasLLMConfig 完全一致（端点/模型齐备 + 密钥或密钥可选预设）
        self.usesLLM = !localDictionaryOnly
            && AppConfig.llmStatus(baseURL: baseURL, apiKey: sanitizedKey, model: model) == .ready
        self.sendsContext = sendsContext
        self.explanationStyle = explanationStyle
        self.streamsResults = streamsResults
    }

    func contextForRequest(_ context: String?) -> String? {
        usesLLM && sendsContext ? context : nil
    }
}

/// 查询代际管理：任何「新查询 / 关闭弹窗 / 暂停 / 新一次取词失败」都应让旧会话失效，
/// 所有增量、成功、失败结果在落到 UI 之前统一用 `isCurrent(_:)` 校验。
///
/// 之前只用 `requestCounter`，且只在「成功拿到新文本」时才递增，于是：关闭弹窗只 cancel 不换代，
/// 旧请求返回后仍能重新弹出释义；新一次取词失败直接展示提示，旧查询返回又能把提示覆盖掉。
@MainActor
final class QuerySession {
    /// 当前有效会话 id；nil = 没有任何在途会话
    private(set) var currentID: Int?
    private var generation = 0

    /// 开始一次新会话，旧会话（若有）立即失效
    @discardableResult
    func begin() -> Int {
        generation += 1
        currentID = generation
        return generation
    }

    /// 让当前会话失效（关闭弹窗 / 暂停 / 展示失败提示）。幂等，可重复调用。
    func invalidate() {
        generation += 1
        currentID = nil
    }

    /// 该会话是否仍是「当前」会话；过期结果一律不得落到 UI 或写历史
    func isCurrent(_ id: Int) -> Bool { currentID == id }
}
