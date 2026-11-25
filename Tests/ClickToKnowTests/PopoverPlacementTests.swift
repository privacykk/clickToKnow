import AppKit
import XCTest

@testable import ClickToKnow

/// 结果弹窗定位（纯函数）：默认贴选区锚点，用户拖动过之后固定左上角，
/// 两种情况都不得越出屏幕可视区。
final class PopoverPlacementTests: XCTestCase {
    /// 模拟一块 1440×900 的屏幕，扣掉菜单栏/程序坞后的可视区仍用这个矩形
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = NSSize(width: 560, height: 200)

    /// 默认放在鼠标右下方，留 16pt 间距
    func testDefaultPlacesBelowRightOfAnchor() {
        let origin = PopoverPlacement.origin(
            size: size, anchor: NSPoint(x: 100, y: 600), pinnedTopLeft: nil, screen: screen
        )
        XCTAssertEqual(origin.x, 116, accuracy: 0.01)
        XCTAssertEqual(origin.y, 384, accuracy: 0.01)
    }

    /// 下方放不下就翻到锚点上方（贴选区上沿，别把选区盖住）
    func testFlipsAboveAnchorWhenNoRoomBelow() {
        let origin = PopoverPlacement.origin(
            size: size, anchor: NSPoint(x: 100, y: 100), pinnedTopLeft: nil, screen: screen
        )
        XCTAssertEqual(origin.y, 116, accuracy: 0.01)
    }

    /// 贴右边缘时回退到留白位置，整窗可见
    func testClampsToRightEdge() {
        let origin = PopoverPlacement.origin(
            size: size, anchor: NSPoint(x: 1400, y: 600), pinnedTopLeft: nil, screen: screen
        )
        XCTAssertEqual(origin.x, screen.maxX - size.width - PopoverPlacement.screenInset, accuracy: 0.01)
    }

    /// 拖动到屏幕右上角之外时整体拉回可视区
    func testClampsPinnedPositionIntoVisibleFrame() {
        let origin = PopoverPlacement.origin(
            size: size, anchor: NSPoint(x: 10, y: 10),
            pinnedTopLeft: NSPoint(x: 1500, y: 1000), screen: screen
        )
        XCTAssertEqual(origin.x, screen.maxX - size.width - PopoverPlacement.screenInset, accuracy: 0.01)
        XCTAssertEqual(origin.y, screen.maxY - size.height - PopoverPlacement.screenInset, accuracy: 0.01)
    }

    /// 拖动过之后：左上角就是用户放的位置（而不是锚点）
    func testPinnedTopLeftIsHonoured() {
        let origin = PopoverPlacement.origin(
            size: NSSize(width: 560, height: 300), anchor: NSPoint(x: 10, y: 10),
            pinnedTopLeft: NSPoint(x: 500, y: 800), screen: screen
        )
        XCTAssertEqual(origin.x, 500, accuracy: 0.01)
        XCTAssertEqual(origin.y, 500, accuracy: 0.01)
    }

    /// 流式内容变高：顶边不动、向下生长（否则会重新盖住刚被让开的选区）
    func testPinnedWindowGrowsDownwardKeepingTopEdge() {
        let short = PopoverPlacement.origin(
            size: NSSize(width: 560, height: 200), anchor: .zero,
            pinnedTopLeft: NSPoint(x: 500, y: 800), screen: screen
        )
        let tall = PopoverPlacement.origin(
            size: NSSize(width: 560, height: 320), anchor: .zero,
            pinnedTopLeft: NSPoint(x: 500, y: 800), screen: screen
        )
        XCTAssertEqual(short.y + 200, 800, accuracy: 0.01)
        XCTAssertEqual(tall.y + 320, 800, accuracy: 0.01)
        XCTAssertEqual(short.x, tall.x, accuracy: 0.01)
    }

    /// 拖动位移：窗口原点跟着鼠标走（屏幕坐标，跨显示器也不失真）
    func testDragAppliesMouseTranslation() {
        let origin = PopoverDrag.origin(
            startOrigin: NSPoint(x: 400, y: 500),
            startMouse: NSPoint(x: 700, y: 640),
            currentMouse: NSPoint(x: 640, y: 700)
        )
        XCTAssertEqual(origin.x, 340, accuracy: 0.01)
        XCTAssertEqual(origin.y, 560, accuracy: 0.01)
    }

    /// 上边缘越界要压回可视区内（断言精确值：删掉上限 clamp 就会失败）
    func testClampsToTopEdge() {
        let origin = PopoverPlacement.origin(
            size: NSSize(width: 560, height: 200), anchor: NSPoint(x: 100, y: 10),
            pinnedTopLeft: NSPoint(x: 500, y: 895), screen: screen
        )
        XCTAssertEqual(origin.y, screen.maxY - 200 - PopoverPlacement.screenInset, accuracy: 0.01)
    }

    /// 窗口比屏幕还高：无法两全时保证左下角在可视区内（而不是算出屏幕外的坐标）
    func testOversizedWindowKeepsBottomLeftVisible() {
        let origin = PopoverPlacement.origin(
            size: NSSize(width: 560, height: 1000), anchor: NSPoint(x: 100, y: 600),
            pinnedTopLeft: nil, screen: screen
        )
        XCTAssertEqual(origin.x, 116, accuracy: 0.01)
        XCTAssertEqual(origin.y, screen.minY + PopoverPlacement.screenInset, accuracy: 0.01)
    }

    /// 拖到贴近屏幕底部后再收到流式内容：底边钉在可视区内、顶边随内容上抬，
    /// 但不能出现「每增长一行就整体上移」的漂移（用户位置只作为意图保留，每帧由 clamp 兜住）。
    func testPinnedNearBottomGrowsWithinScreen() {
        let short = PopoverPlacement.origin(
            size: NSSize(width: 560, height: 200), anchor: .zero,
            pinnedTopLeft: NSPoint(x: 500, y: 129), screen: screen
        )
        let tall = PopoverPlacement.origin(
            size: NSSize(width: 560, height: 400), anchor: .zero,
            pinnedTopLeft: NSPoint(x: 500, y: 129), screen: screen
        )
        XCTAssertEqual(short.y, screen.minY + PopoverPlacement.screenInset, accuracy: 0.01)
        XCTAssertEqual(tall.y, screen.minY + PopoverPlacement.screenInset, accuracy: 0.01)
        // 顶边 = 底边 + 高度，且不越出屏幕
        XCTAssertLessThanOrEqual(tall.y + 400, screen.maxY)
    }
}