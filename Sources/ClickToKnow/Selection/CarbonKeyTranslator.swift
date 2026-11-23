import AppKit
import Carbon.HIToolbox

/// 快捷键绑定：Carbon 虚拟键码 + 修饰键位掩码，可输出人类可读展示串（如 ⌥⌘K）。
struct HotKeyBinding: Codable, Equatable {
    /// Carbon 虚拟键码（kVK_* 常量）
    var keyCode: UInt32
    /// Carbon 修饰键位掩码：cmdKey=256 / shiftKey=512 / optionKey=2048 / controlKey=4096
    var carbonModifiers: UInt32

    /// 人类可读展示串（如 ⌥⌘K）
    var displayString: String {
        CarbonKeyTranslator.displayString(keyCode: keyCode, modifiers: carbonModifiers)
    }
}

/// keyCode / 修饰键翻译工具：纯函数无状态，便于单测。
enum CarbonKeyTranslator {
    /// 默认 ⌥⌘K（⌥⌘D 与系统「显示/隐藏 Dock」冲突，沿用 SelectionMonitor 原选型）
    static let defaultBinding = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_K),
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    /// 修饰键展示顺序固定 ⌃⌥⇧⌘（与 macOS 菜单快捷键惯例一致）
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += keyName(for: keyCode)
        return text
    }

    /// 未收录键回退 "KeyCode(n)"，保证任何绑定都有可展示的字符串
    static func keyName(for keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "KeyCode(\(keyCode))"
    }

    /// NSEvent 修饰键 → Carbon 位掩码（录制控件捕获 NSEvent，热键注册用 Carbon）
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// 合法全局快捷键至少含 ⌘/⌥/⌃ 之一；纯 ⇧ 或无修饰单键冲突面过大，一律拒绝
    static func hasRequiredModifier(_ carbonModifiers: UInt32) -> Bool {
        carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    /// 常用 keyCode → 键名映射（字母/数字/符号/F 区/方向/小键盘）
    private static let keyNames: [Int: String] = [
        // 字母
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        // 数字
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        // 符号
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        // 控制键
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "空格",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        // 方向与导航
        kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        // F 区
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        // 小键盘
        kVK_ANSI_Keypad0: "Pad0", kVK_ANSI_Keypad1: "Pad1", kVK_ANSI_Keypad2: "Pad2",
        kVK_ANSI_Keypad3: "Pad3", kVK_ANSI_Keypad4: "Pad4", kVK_ANSI_Keypad5: "Pad5",
        kVK_ANSI_Keypad6: "Pad6", kVK_ANSI_Keypad7: "Pad7", kVK_ANSI_Keypad8: "Pad8",
        kVK_ANSI_Keypad9: "Pad9",
        kVK_ANSI_KeypadDecimal: "Pad.", kVK_ANSI_KeypadMultiply: "Pad*",
        kVK_ANSI_KeypadPlus: "Pad+", kVK_ANSI_KeypadMinus: "Pad-",
        kVK_ANSI_KeypadDivide: "Pad/", kVK_ANSI_KeypadEquals: "Pad=",
        kVK_ANSI_KeypadEnter: "⌤", kVK_ANSI_KeypadClear: "⌧"
    ]
}
