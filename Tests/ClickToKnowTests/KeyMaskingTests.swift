import XCTest

@testable import ClickToKnow

/// AppConfig.mask 掩码规则的验证：长键保留前后 4 位，短键全打点，绝不泄漏中段。
final class KeyMaskingTests: XCTestCase {
    func testLongKeyKeepsFirstFourAndLastFour() {
        XCTAssertEqual(AppConfig.mask("sk-abcdef123456"), "sk-a••••3456")
    }

    func testShortKeyIsFullyMasked() {
        XCTAssertEqual(AppConfig.mask("abc123"), "••••••")
        XCTAssertEqual(AppConfig.mask("12345678"), "••••••••")
    }

    func testEmptyKeyMasksToEmpty() {
        XCTAssertEqual(AppConfig.mask(""), "")
    }

    func testMaskNeverLeaksMiddleOfKey() {
        let key = "sk-proj-0123456789abcdefghij"
        let masked = AppConfig.mask(key)
        XCTAssertFalse(masked.contains("56789"))
        XCTAssertTrue(masked.hasPrefix("sk-p"))
        XCTAssertTrue(masked.hasSuffix("ghij"))
    }
}
