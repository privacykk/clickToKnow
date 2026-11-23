import Carbon.HIToolbox

/// 基于 Carbon `RegisterEventHotKey` 的全局快捷键（菜单栏 accessory 应用没有主窗口，
/// 用 NSEvent 全局监听不可靠，Carbon 热键是标准做法）。
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    /// 是否已成功注册（供热键更换流程判断）
    var isRegistered: Bool { hotKeyRef != nil }

    /// 注册全局热键；重复注册前先注销旧绑定。返回是否成功（冲突等失败不抛错）。
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        unregister()
        self.action = action

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4354_4B4B) // "CTKK"
        hotKeyID.id = 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Carbon 事件回调在主 runloop 上分发，回调里同步调用 action
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.action?()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        guard installStatus == noErr else { return false }

        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            // 注册失败时清掉刚装的事件处理器，避免残留 handler 指向 self
            unregister()
            return false
        }
        return true
    }

    /// 注销热键与事件处理器（幂等；应用退出或更换绑定前调用）
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = handlerRef {
            RemoveEventHandler(ref)
            handlerRef = nil
        }
        action = nil
    }
}