import AppKit
import ApplicationServices
import Security

/// 辅助功能（TCC）授权状态。
///
/// 为什么需要三态：系统把授权按「代码签名要求（csreq）」记录，而 ad-hoc 签名的要求
/// 就是二进制自身的 cdhash。覆盖安装（重新打包）后 cdhash 变了，系统设置列表里仍留着
/// 旧条目、开关看起来还是开的，但 AXIsProcessTrusted() 返回 false——只有在面板里重新
/// 勾选（关闭再打开）或移除后重新添加，系统才会写入新的 csreq。
/// 这里用「上次确认授权时的 cdhash」识别这种失效，给出针对性的修复入口，
/// 而不是笼统显示「未授权」把用户引到一个已经勾选的面板上。
enum AccessibilityPermissionState: Equatable {
    /// 已授权，可用
    case granted
    /// 从未授权过（或用户主动撤销）
    case notGranted
    /// 曾授权成功，但当前二进制签名与授权时的记录不一致：系统里的条目已失效
    case invalidated
}

/// 授权记录：把「最后一次确认可用的代码签名」落到配置 plist，
/// 用于区分「从未授权」与「授权因签名变更而失效」。
struct AccessibilityGrantRecord {
    /// 记录签名的键；与 AppConfig 同 suite，覆盖安装后仍然保留（新版本才能做对比）
    static let signatureKey = "accessibilityGrantedSignature"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: "ClickToKnow") ?? .standard) {
        self.defaults = defaults
    }

    /// 结合系统实时结果与本机记录产出三态；授权成功时顺手刷新记录
    func state(trusted: Bool, signature: String?) -> AccessibilityPermissionState {
        if trusted {
            // 仅在签名变化时写盘：状态页每秒轮询，避免无谓的 UserDefaults 写入
            if let signature, defaults.string(forKey: Self.signatureKey) != signature {
                defaults.set(signature, forKey: Self.signatureKey)
            }
            return .granted
        }
        // 没有历史记录 = 从未授权过，无可对比的依据
        guard let recorded = defaults.string(forKey: Self.signatureKey), !recorded.isEmpty else {
            return .notGranted
        }
        // 取不到当前签名（极少见）时不做「已失效」判断，避免误导
        guard let signature else { return .notGranted }
        return recorded == signature ? .notGranted : .invalidated
    }

    /// 丢弃记录：TCC 条目被重置后，系统会按当前签名重新记录，旧记录不再有对比意义
    func forget() {
        defaults.removeObject(forKey: Self.signatureKey)
    }
}

/// 当前进程的代码签名 cdhash（十六进制）。进程生命周期内不会变化，取一次即可。
enum CodeSignature {
    /// ad-hoc 与证书签名都会产出 cdhash；拿不到时返回 nil（例如完全未签名的二进制）
    static let current: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        // universal binary 每个架构各有一个 cdhash：排序后拼接，合并顺序变化也不会误判
        guard let hashes = dict[kSecCodeInfoCdHashes as String] as? [Data], !hashes.isEmpty else { return nil }
        return hashes
            .map { $0.map { String(format: "%02x", $0) }.joined() }
            .sorted()
            .joined(separator: "+")
    }()
}
