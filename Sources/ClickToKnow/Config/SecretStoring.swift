import Foundation

enum SecretRead: Equatable {
    case value(String)
    case missing
    case inaccessible
}

/// 生产使用钥匙串，测试注入独立存储。静默读取失败与条目不存在须区分。
protocol SecretStoring {
    func read(account: String, allowInteraction: Bool) -> SecretRead
    func save(_ value: String, account: String) -> Bool
    func delete(account: String) -> Bool
}

struct KeychainSecrets: SecretStoring {
    func read(account: String, allowInteraction: Bool) -> SecretRead {
        KeychainSecretStore.read(account: account, allowInteraction: allowInteraction)
    }

    func save(_ value: String, account: String) -> Bool {
        KeychainSecretStore.save(value, account: account)
    }

    func delete(account: String) -> Bool {
        KeychainSecretStore.delete(account: account)
    }
}
