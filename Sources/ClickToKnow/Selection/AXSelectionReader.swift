import AppKit
import ApplicationServices

/// AX 直读选中文本：主取词路径。相对模拟 ⌘C 的优势——
/// 不碰剪贴板（无快照/恢复竞态）、对禁复制应用（受保护 PDF 等）有效、
/// 顺带拿选区屏幕矩形（弹窗贴选区而非鼠标）与前后文（LLM 领域判断素材）。
///
/// 读取失败（目标应用未实现 AX、返回空、IPC 超时）返回 nil，调用方回退 ⌘C 路径。
enum AXSelectionReader {
    struct Result: Sendable {
        let text: String
        /// 选区在屏幕上的矩形（AppKit 左下原点坐标系）；取不到为 nil（弹窗回退鼠标定位）
        let rect: NSRect?
        /// 选区前后文（约 ±200 字符）；取不到为 nil
        let context: String?
    }

    /// 单次取词等待 AX 的总预算
    static let defaultTimeout: TimeInterval = 0.4

    /// 单次 AX IPC 的 messaging timeout。
    /// 系统默认 6 秒，远大于我们的 400ms 预算：不设的话「外层超时返回、后台线程仍挂着 IPC」
    /// 会一直占着线程，快速连按慢应用时未完成调用持续累积。压到 200ms 让 IPC 自己先失败。
    static let messagingTimeout: Float = 0.2

    /// 读取前台应用选区（主线程调用：NSScreen / NSWorkspace 有线程约束）。
    /// AX IPC 在后台队列执行并用 continuation 等待——主线程不再 semaphore 同步阻塞。
    @MainActor
    static func readFrontmost(timeout: TimeInterval = defaultTimeout, includeContext: Bool = true) async -> Result? {
        // 前台应用即取词目标：全局热键触发时本应用并未激活，frontmost 仍是用户正在用的 App
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        // 坐标翻转需要主屏高度：NSScreen 只能在主线程访问，提前取好传入后台
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return await read(pid: app.processIdentifier, primaryHeight: primaryHeight, timeout: timeout,
                          includeContext: includeContext)
    }

    /// 异步读取指定进程的选区：超时返回 nil（调用方回退 ⌘C）。
    /// 超时后仍卡住的 IPC 线程由 messaging timeout 兜底结束，不会被无限期占用。
    static func read(
        pid: pid_t, primaryHeight: CGFloat, timeout: TimeInterval = defaultTimeout, includeContext: Bool = true
    ) async -> Result? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            // 工作线程与超时定时器会竞争同一个 continuation，必须保证只 resume 一次
            let gate = ResumeGate()
            DispatchQueue.global(qos: .userInitiated).async {
                let result = readViaAX(pid: pid, primaryHeight: primaryHeight, includeContext: includeContext)
                gate.resume(continuation, with: result)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                gate.resume(continuation, with: nil)
            }
        }
    }

    // MARK: - AX IPC（后台线程）

    private static func readViaAX(pid: pid_t, primaryHeight: CGFloat, includeContext: Bool) -> Result? {
        let appElement = AXUIElementCreateApplication(pid)
        // 先设 messaging timeout：后面每一次 IPC 都受它约束
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        // AX 约定：focused UI element 属性必为 AXUIElement，强转是标准用法
        let element = focused as! AXUIElement
        // 子元素的超时不随父元素继承，逐个设置
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let text = textRef as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let range = selectedRange(of: element)
        return Result(
            text: text,
            rect: range.flatMap { selectionRect(of: element, range: $0, primaryHeight: primaryHeight) },
            context: includeContext ? range.flatMap { surroundingContext(of: element, range: $0, selectedText: text) } : nil
        )
    }

    /// 选区的字符区间（AXValue CFRange）
    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        // AX 约定：该属性必为 AXValue(CFRange)，强转是标准用法
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// 选区屏幕矩形：AX 返回左上原点坐标，换算成 AppKit 的左下原点（以主屏高度翻转）
    private static func selectionRect(of element: AXUIElement, range: CFRange, primaryHeight: CGFloat) -> NSRect? {
        var range = range
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var rectRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &rectRef
        ) == .success, let rectValue = rectRef else { return nil }

        // AX 约定：bounds 属性必为 AXValue(CGRect)，强转是标准用法
        var axRect = CGRect.zero
        guard AXValueGetValue(rectValue as! AXValue, .cgRect, &axRect), !axRect.isEmpty else { return nil }

        return NSRect(
            x: axRect.minX,
            y: primaryHeight - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
    }

    /// 选区前后 ±200 字符作为上下文；元素不支持按区间取文本时退回全文截断
    private static func surroundingContext(of element: AXUIElement, range: CFRange, selectedText: String) -> String? {
        var countRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let total = countRef as? Int, total > range.length else { return nil }

        let margin = 200
        let lower = max(0, range.location - margin)
        let upper = min(total, range.location + range.length + margin)
        guard upper > lower else { return nil }

        var window = CFRange(location: lower, length: upper - lower)
        guard let windowValue = AXValueCreate(.cfRange, &window) else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, windowValue, &textRef
        ) == .success, let text = textRef as? String, !text.isEmpty else { return nil }

        // 防御：个别实现返回的区间文本不含选中词（富文本偏移），此时上下文反而误导 LLM
        return text.contains(selectedText.trimmingCharacters(in: .whitespacesAndNewlines)) ? text : nil
    }
}

/// 保证 continuation 只被 resume 一次（工作线程与超时定时器竞争时的收尾闸门）
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<AXSelectionReader.Result?, Never>, with value: AXSelectionReader.Result?) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// AX 直读抽象：单测注入假实现，避免依赖真实辅助功能授权与前台应用
@MainActor
protocol SelectionReading {
    func read() async -> AXSelectionReader.Result?
}

/// 生产实现：读前台应用选区（⌥⌘K 触发时本应用未激活，frontmost 即是取词目标）
struct AXSelectionReaderAdapter: SelectionReading {
    func read() async -> AXSelectionReader.Result? {
        let config = AppConfig.shared
        return await AXSelectionReader.readFrontmost(includeContext: !config.localDictionaryOnly && config.sendsQueryContext)
    }
}
