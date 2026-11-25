import Foundation
import XCTest

@testable import ClickToKnow

/// 测试公共工具。
enum TestHelpers {
    /// 兼容两种请求体载体读取 POST body（URLProtocol mock 断言请求内容用）
    static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// 可断言的内存密钥存储，替代真实钥匙串。
    ///
    /// 用真钥匙串跑单测有两个问题：一是会读写开发者本机真实密钥（迁移用例可能顺手把真密钥挪走），
    /// 二是「写入失败」这条路根本不可控——而那正是密钥隔离缺陷的触发条件。
    final class InMemorySecretStore: SecretStoring {
        /// account → 密钥。测试可直接预置初始状态。
        var storage: [String: String]
        /// true = 模拟钥匙串不可用/写入被拒（ad-hoc 签名场景）
        var isAvailable: Bool
        /// 写入是否失败；仅 save 受影响，delete 仍按 isAvailable 走
        var failSaves: Bool
        var lockedAccounts: Set<String> = []
        var grantInteraction = true
        private(set) var interactiveReads: [String] = []
        /// 记录所有写入调用，便于断言「B 的密钥没有被写进 A 的条目」
        private(set) var savedAccounts: [String] = []
        /// 记录所有删除调用
        private(set) var deletedAccounts: [String] = []

        init(storage: [String: String] = [:], isAvailable: Bool = true, failSaves: Bool = false) {
            self.storage = storage
            self.isAvailable = isAvailable
            self.failSaves = failSaves
        }

        func read(account: String, allowInteraction: Bool) -> SecretRead {
            if allowInteraction { interactiveReads.append(account) }
            guard isAvailable else { return .inaccessible }
            if lockedAccounts.contains(account) {
                guard allowInteraction && grantInteraction else { return .inaccessible }
                lockedAccounts.remove(account)
            }
            return storage[account].map(SecretRead.value) ?? .missing
        }

        @discardableResult
        func save(_ value: String, account: String) -> Bool {
            savedAccounts.append(account)
            guard isAvailable, !failSaves else { return false }
            storage[account] = value
            return true
        }

        @discardableResult
        func delete(account: String) -> Bool {
            deletedAccounts.append(account)
            guard isAvailable else { return false }
            storage.removeValue(forKey: account)
            return true
        }
    }
}
