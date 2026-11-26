import AppKit
import Foundation

/// 读取 `.app` 的显示名与 Bundle ID。
///
/// 禁止取词规则只以 Bundle ID 匹配（不依赖安装路径，应用移动后仍有效），
/// 显示名只是给人看的：优先读应用自己的 CFBundleDisplayName / CFBundleName，
/// 列表里则按 Bundle ID 反查已安装应用，应用被删或改名时退回显示 ID。
enum AppBundleInfo {
    /// 读取应用到 Bundle ID；不是应用、Info.plist 损坏或缺少标识时返回 nil
    static func bundleID(at url: URL) -> String? {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        guard let bundle = Bundle(url: url) else { return nil }
        guard let identifier = bundle.bundleIdentifier, !identifier.isEmpty else { return nil }
        return identifier
    }

    /// 读取应用显示名：CFBundleDisplayName → CFBundleName → 去掉 .app 的文件名
    static func displayName(at url: URL) -> String {
        if let bundle = Bundle(url: url) {
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return name
            }
            if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !name.trimmingCharacters(in: .whitespaces).isEmpty {
                return name
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// 按 Bundle ID 找已安装应用的显示名；找不到返回 nil（调用方退回显示 ID）
    static func installedName(forBundleID identifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return nil
        }
        return displayName(at: url)
    }

    /// 列表行的标题与副标题：有可读名称时标题用名称、副标题留 Bundle ID 便于核对
    static func label(forBundleID identifier: String) -> (title: String, subtitle: String?) {
        guard let name = installedName(forBundleID: identifier), name != identifier else {
            return (identifier, nil)
        }
        return (name, identifier)
    }
}