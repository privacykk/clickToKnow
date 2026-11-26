import XCTest

@testable import ClickToKnow

/// 选择应用程序加入禁止名单：只依赖 Bundle ID 匹配，显示名读不到时要能优雅退回。
final class AppBundleInfoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickToKnowAppInfo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        root = nil
        super.tearDown()
    }

    /// 造一个只有 Info.plist 的 .app（不需要可执行文件，读标识/名称即可）
    private func makeApp(_ name: String, info: [String: Any]) throws -> URL {
        let app = root.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    func test_readsBundleIdentifierAndDisplayName() throws {
        let app = try makeApp("Demo", info: [
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleName": "DemoName",
            "CFBundleDisplayName": "演示应用",
            "CFBundlePackageType": "APPL",
        ])

        XCTAssertEqual(AppBundleInfo.bundleID(at: app), "com.example.demo")
        XCTAssertEqual(AppBundleInfo.displayName(at: app), "演示应用", "优先用 CFBundleDisplayName")
    }

    func test_displayNameFallsBackToBundleNameThenFileName() throws {
        let withoutDisplay = try makeApp("NoDisplay", info: [
            "CFBundleIdentifier": "com.example.nodesplay",
            "CFBundleName": "BundleNameOnly",
        ])
        XCTAssertEqual(AppBundleInfo.displayName(at: withoutDisplay), "BundleNameOnly")

        let plain = try makeApp("PlainApp", info: ["CFBundleIdentifier": "com.example.plain"])
        XCTAssertEqual(AppBundleInfo.displayName(at: plain), "PlainApp", "没有名称字段时用文件名")
    }

    func test_nonAppPathIsRejected() throws {
        let file = root.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(AppBundleInfo.bundleID(at: file), "普通文件不得被当成应用")
    }

    func test_appWithoutInfoPlistIsRejected() throws {
        let app = root.appendingPathComponent("Broken.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertNil(AppBundleInfo.bundleID(at: app), "缺少 Bundle ID 时不得新增规则")
    }

    /// 未安装的 Bundle ID 退回显示 ID 本身（列表不会出现空白行）
    func test_labelFallsBackToIdentifierForUnknownApp() {
        let identifier = "com.example.not-installed-\(UUID().uuidString)"
        let label = AppBundleInfo.label(forBundleID: identifier)
        XCTAssertEqual(label.title, identifier)
        XCTAssertNil(label.subtitle)
    }
}