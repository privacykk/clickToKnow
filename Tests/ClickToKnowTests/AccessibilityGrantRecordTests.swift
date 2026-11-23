import XCTest

@testable import ClickToKnow

/// 辅助功能授权三态判定：区分「从未授权」与「覆盖安装后签名变更导致授权失效」。
/// 这是修复「系统设置里列表还有条目、却显示未授权」的关键依据，用独立 suite 避免污染真实配置。
final class AccessibilityGrantRecordTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var record: AccessibilityGrantRecord!

    override func setUp() {
        super.setUp()
        suiteName = "AccessibilityGrantRecordTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        record = AccessibilityGrantRecord(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        record = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// 没有任何记录 = 从未授权过，不能误报成「授权失效」
    func test_neverGranted() {
        XCTAssertEqual(record.state(trusted: false, signature: "aaa"), .notGranted)
    }

    /// 授权成功时记录当前签名
    func test_grantedRecordsSignature() {
        XCTAssertEqual(record.state(trusted: true, signature: "aaa"), .granted)
        XCTAssertEqual(defaults.string(forKey: AccessibilityGrantRecord.signatureKey), "aaa")
    }

    /// 同一签名下被系统判定未授权（用户主动关闭开关）= 普通未授权
    func test_sameSignatureUntrustedIsNotGranted() {
        _ = record.state(trusted: true, signature: "aaa")
        XCTAssertEqual(record.state(trusted: false, signature: "aaa"), .notGranted)
    }

    /// 签名变了且不再被信任：覆盖安装的典型症状，判为失效
    func test_changedSignatureIsInvalidated() {
        _ = record.state(trusted: true, signature: "aaa")
        XCTAssertEqual(record.state(trusted: false, signature: "bbb"), .invalidated)
    }

    /// 取不到当前签名时不做失效判断，避免把「无法读取签名」误报成授权失效
    func test_missingSignatureFallsBackToNotGranted() {
        _ = record.state(trusted: true, signature: "aaa")
        XCTAssertEqual(record.state(trusted: false, signature: nil), .notGranted)
    }

    /// 授权签名只写一次：轮询期间签名不变就不重复写盘
    func test_recordIsNotRewrittenWhenUnchanged() {
        _ = record.state(trusted: true, signature: "aaa")
        _ = record.state(trusted: true, signature: "aaa")
        XCTAssertEqual(defaults.string(forKey: AccessibilityGrantRecord.signatureKey), "aaa")
    }

    /// 修复授权后记录被清除，重新开始一轮「未授权 → 授权」流程
    func test_forgetClearsRecord() {
        _ = record.state(trusted: true, signature: "aaa")
        record.forget()
        XCTAssertNil(defaults.string(forKey: AccessibilityGrantRecord.signatureKey))
        XCTAssertEqual(record.state(trusted: false, signature: "bbb"), .notGranted)
    }
}
