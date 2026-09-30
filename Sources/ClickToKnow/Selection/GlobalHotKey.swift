import Carbon.HIToolbox

/// 基于 Carbon `RegisterEventHotKey` 的全局快捷键（菜单栏 accessory 应用没有主窗口，
/// 用 NSEvent 全局监听不可靠，Carbon 热键是标准做法）。
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    var isRegistered: Bool { hotKeyRef != nil }

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

        return registerStatus == noErr
    }

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