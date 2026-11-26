import CryptoKit
import Foundation

/// 本地历史复用的查询指纹：稳定、带版本，不含密钥，也不含上下文原文。
///
/// 维度与进程内缓存键完全一致（词条、上下文摘要、来源、端点、模型、协议 / 配置 / 模板），
/// 任一项不同都不复用——否则会把「航海语境的 helm」当成「K8s 的 helm」返回。
/// 用 SHA-256 而不是 Swift 的 `hashValue`：后者每个进程随机，重启后无法命中。
enum QueryFingerprint {
    /// 指纹版本：维度或语义变化时递增，旧指纹自然失效（不会与新语义串用）
    static let version = "1"

    /// 由缓存键派生，保证「缓存怎么分键，历史就怎么复用」
    static func make(from key: InterpretationCache.Key) -> String {
        let parts = [
            version,
            key.source.rawValue,
            key.baseURL,
            key.model,
            key.term,
            key.contextDigest,
            key.promptFingerprint,
        ]
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return "v\(version)-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 按查询参数生成（历史写入与查找共用同一入口，避免两处维度漂移）
    static func make(
        term: String, context: String?, source: Interpretation.Source, baseURL: String,
        model: String, apiProtocol: APIProtocol, profileID: UUID?,
        explanationStyle: ExplanationStyle = .technical
    ) -> String {
        make(from: InterpretationCache.key(
            term: term,
            context: context,
            source: source,
            baseURL: baseURL,
            model: model,
            apiProtocol: apiProtocol,
            profileID: profileID,
            explanationStyle: explanationStyle
        ))
    }
}