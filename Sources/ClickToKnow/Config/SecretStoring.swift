import Foundation

/// 密钥存储抽象。AppConfig 只依赖该协议，生产实现是钥匙串（`KeychainSecrets`）。
///
/// 抽出这层的目的不是「为了抽象而抽象」：密钥隔离这类缺陷只在钥匙串写入失败、
/// 生效配置切换、旧数据迁移这几条路径上才暴露，而这些路径没法靠真实钥匙串复现
/// （ad-hoc 签名下可用性还随重编译变化）。注入一个可失败的实现，才能把
/// 「A 保存失败 → 切到 B → B 不得拿到 A 的密钥」写成回归测试。
protocol SecretStoring {
    /// 存储是否可用（钥匙串在 ad-hoc 签名 / 授权被拒时为不可用）
    var isAvailable: Bool { get }
    /// 读取指定 account；不存在或不可读返回 nil
    func load(account: String) -> String?
    /// 写入（已存在则覆盖）。返回是否成功，失败由调用方决定回退策略
    @discardableResult
    func save(_ value: String, account: String) -> Bool
    /// 删除幂等：条目不存在视为成功。返回是否确认删除成功
    @discardableResult
    func delete(account: String) -> Bool
}

/// 生产实现：原样转发到钥匙串。无状态，可安全共享。
struct KeychainSecrets: SecretStoring {
    var isAvailable: Bool { KeychainSecretStore.isAvailable }
    func load(account: String) -> String? { KeychainSecretStore.load(account: account) }
    @discardableResult
    func save(_ value: String, account: String) -> Bool {
        KeychainSecretStore.save(value, account: account)
    }
    @discardableResult
    func delete(account: String) -> Bool { KeychainSecretStore.delete(account: account) }
}