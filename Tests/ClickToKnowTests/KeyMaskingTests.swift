import XCTest

@testable import ClickToKnow

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
