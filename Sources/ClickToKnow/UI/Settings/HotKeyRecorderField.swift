import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 快捷键录制控件：点击进入录制态（高亮边框），按下新组合回调，Esc 取消。
/// 用 NSViewRepresentable 实现：捕获 keyDown 需要 first responder 身份，纯 SwiftUI 无等价能力。
struct HotKeyRecorderField: NSViewRepresentable {
    /// 非录制态展示的占位文案（当前绑定显示串）
    let placeholder: String
    /// 捕获到合法组合时回调（已通过修饰键校验）
    var onCapture: (HotKeyBinding) -> Void
    /// Esc 取消录制时回调
    var onCancel: () -> Void = {}

    /// 创建底层录制视图并同步回调
    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.placeholder = placeholder
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    /// SwiftUI 更新时同步回调与占位文案（闭包每次重建，需无条件刷新）
    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        if nsView.placeholder != placeholder {
            nsView.placeholder = placeholder
        }
    }

    final class RecorderView: NSView {
        var onCapture: ((HotKeyBinding) -> Void)?
        var onCancel: (() -> Void)?
        /// 占位文案（变化即重绘）
        var placeholder: String = "" {
            didSet { needsDisplay = true }
        }

        /// 录制态跟随 first responder 身份，避免外部状态与焦点不同步
        private var isRecording = false {
            didSet { needsDisplay = true }
        }

        override var acceptsFirstResponder: Bool { true }

        /// 点击进入录制态（夺取 first responder）
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func becomeFirstResponder() -> Bool {
            isRecording = true
            return super.becomeFirstResponder()
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        /// 键盘捕获：Esc 取消；Tab 放行给焦点导航；非法组合 beep；合法组合回调 onCapture
        override func keyDown(with event: NSEvent) {
            if event.keyCode == UInt16(kVK_Escape) {
                window?.makeFirstResponder(nil)
                onCancel?()
                return
            }
            let modifiers = CarbonKeyTranslator.carbonModifiers(from: event.modifierFlags)
            guard CarbonKeyTranslator.hasRequiredModifier(modifiers) else {
                // Tab / ⇧Tab 必须放行，否则录制态会把键盘焦点锁死在框内；其余非法组合 beep 提示
                if event.keyCode == UInt16(kVK_Tab) {
                    if event.modifierFlags.contains(.shift) {
                        window?.selectPreviousKeyView(nil)
                    } else {
                        window?.selectNextKeyView(nil)
                    }
                    return
                }
                NSSound.beep() // 无修饰键或纯 ⇧ 的组合一律拒绝
                return
            }
            window?.makeFirstResponder(nil)
            onCapture?(HotKeyBinding(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers))
        }

        /// 自绘：录制态用强调色粗边框，居中显示提示/占位文案
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()

            let text = isRecording
                ? "按下新快捷键（Esc 取消）"
                : (placeholder.isEmpty ? "点击录制" : placeholder)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(
                at: NSPoint(x: (bounds.width - size.width) / 2,
                            y: (bounds.height - size.height) / 2),
                withAttributes: attrs
            )
        }
    }
}
