import Carbon.HIToolbox
import XCTest

@testable import ClickToKnow

/// CarbonKeyTranslator 纯函数的行为验证：默认绑定、展示顺序、键名回退、修饰键映射与校验。
final class CarbonKeyTranslatorTests: XCTestCase {
    /// 默认绑定应显示为 ⌥⌘K
    func testDefaultBindingDisplaysOptionCommandK() {
        XCTAssertEqual(CarbonKeyTranslator.defaultBinding.displayString, "⌥⌘K")
    }

    func testModifierDisplayOrderIsControlOptionShiftCommand() {
        let binding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_J),
            carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
        XCTAssertEqual(binding.displayString, "⌃⌥⇧⌘J")
    }

    func testUnknownKeyCodeFallsBackToNumberedPlaceholder() {
        let binding = HotKeyBinding(keyCode: 9999, carbonModifiers: UInt32(cmdKey))
        XCTAssertEqual(binding.displayString, "⌘KeyCode(9999)")
    }

    func testNSEventFlagsMapToCarbonMasks() {
        XCTAssertEqual(
            CarbonKeyTranslator.carbonModifiers(from: [.command, .option]),
            UInt32(cmdKey | optionKey)
        )
        XCTAssertEqual(
            CarbonKeyTranslator.carbonModifiers(from: [.control, .shift]),
            UInt32(controlKey | shiftKey)
        )
        XCTAssertEqual(CarbonKeyTranslator.carbonModifiers(from: []), 0)
    }

    func testRequiredModifierRejectsBareAndShiftOnly() {
        XCTAssertFalse(CarbonKeyTranslator.hasRequiredModifier(0))
        XCTAssertFalse(CarbonKeyTranslator.hasRequiredModifier(UInt32(shiftKey)))
        XCTAssertTrue(CarbonKeyTranslator.hasRequiredModifier(UInt32(cmdKey)))
        XCTAssertTrue(CarbonKeyTranslator.hasRequiredModifier(UInt32(optionKey)))
        XCTAssertTrue(CarbonKeyTranslator.hasRequiredModifier(UInt32(controlKey)))
        XCTAssertTrue(CarbonKeyTranslator.hasRequiredModifier(UInt32(cmdKey | shiftKey)))
    }

    func testFunctionAndNavigationKeyNames() {
        XCTAssertEqual(CarbonKeyTranslator.keyName(for: UInt32(kVK_F5)), "F5")
        XCTAssertEqual(CarbonKeyTranslator.keyName(for: UInt32(kVK_LeftArrow)), "←")
        XCTAssertEqual(CarbonKeyTranslator.keyName(for: UInt32(kVK_Space)), "空格")
        XCTAssertEqual(CarbonKeyTranslator.keyName(for: UInt32(kVK_ANSI_Z)), "Z")
    }
}
