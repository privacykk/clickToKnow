import Carbon.HIToolbox
import XCTest

@testable import ClickToKnow

/// 快捷键绑定持久化 round-trip。使用独立 suite（带 UUID 防冲突），tearDown 清理，不污染真实配置。
/// 注意：removePersistentDomain 只清 cfprefsd 内存域，~/Library/Preferences/<suite>.plist
/// 磁盘文件会残留（实测三种写法对照：仅此域删除=残留；`defaults delete` 子进程=残留；
/// FileManager 直接删文件=干净），故采用 FileManager 显式删除。
final class AppConfigHotKeyTests: XCTestCase {
    private let suiteName = "ClickToKnowTests-\(UUID().uuidString)"
    private var defaults: UserDefaults!
    private var config: AppConfig!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        config = AppConfig(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        config = nil
        // removePersistentDomain 只清内存域、不删磁盘文件（实测 `defaults delete` 子进程
        // 也会残留），FileManager 直接删除 ~/Library/Preferences/<suite>.plist 才干净
        let plistPath = NSHomeDirectory() + "/Library/Preferences/\(suiteName).plist"
        try? FileManager.default.removeItem(atPath: plistPath)
        super.tearDown()
    }

    func testDefaultBindingWhenNothingPersisted() {
        XCTAssertEqual(config.hotKeyBinding, CarbonKeyTranslator.defaultBinding)
        XCTAssertEqual(config.hotKeyBinding.displayString, "⌥⌘K")
    }

    func testBindingRoundTripsThroughUserDefaults() {
        let binding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_J),
            carbonModifiers: UInt32(cmdKey | controlKey | optionKey)
        )
        config.hotKeyBinding = binding
        XCTAssertEqual(config.hotKeyBinding, binding)

        // 新实例回读，验证确实持久化而非内存态
        let reopened = AppConfig(defaults: defaults)
        XCTAssertEqual(reopened.hotKeyBinding, binding)
        XCTAssertEqual(reopened.hotKeyBinding.displayString, "⌃⌥⌘J")
    }

    /// 持久化值损坏（缺 ⌘/⌥/⌃）时回退默认绑定，避免注册成全局裸键
    func testCorruptPersistedBindingFallsBackToDefault() {
        defaults.set(Int(kVK_ANSI_J), forKey: "hotKeyKeyCode")
        defaults.set(Int(shiftKey), forKey: "hotKeyModifiers")
        XCTAssertEqual(config.hotKeyBinding, CarbonKeyTranslator.defaultBinding)
        XCTAssertEqual(config.hotKeyBinding.displayString, "⌥⌘K")
    }

    func testSettingBindingPostsNotification() {
        let expectation = expectation(
            forNotification: AppConfig.hotKeyBindingChangedNotification,
            object: nil
        )
        config.hotKeyBinding = HotKeyBinding(
            keyCode: UInt32(kVK_ANSI_B),
            carbonModifiers: UInt32(cmdKey)
        )
        wait(for: [expectation], timeout: 1.0)
    }
}
