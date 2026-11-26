import Foundation

/// 历史相关文件的位置与占用统计。
///
/// 历史只保存在本机 `Application Support/ClickToKnow`，不上传、不做应用级加密；
/// 这里同时是「存储位置与磁盘占用」展示的单一事实来源。
struct HistoryFiles: Sendable {
    /// 备份文件类型：升级前的旧 JSON 快照 / 无法解析的旧文件
    enum BackupKind: String, Sendable {
        case migrated
        case corrupt
    }

    struct Backup: Identifiable, Equatable, Sendable {
        let name: String
        let bytes: Int64
        let kind: BackupKind
        var id: String { name }
    }

    static let databaseName = "history.sqlite3"
    /// 旧版（JSON）历史文件名；升级后改名为 migratedJSONName
    static let legacyJSONName = "history.json"
    static let migratedJSONName = "history.migrated.json"
    /// 旧版损坏文件的备份前缀
    static let corruptPrefix = "history.corrupt-"

    let directory: URL

    var databaseURL: URL { directory.appendingPathComponent(Self.databaseName) }
    var legacyJSONURL: URL { directory.appendingPathComponent(Self.legacyJSONName) }
    var migratedJSONURL: URL { directory.appendingPathComponent(Self.migratedJSONName) }

    /// 数据库实际占用：主文件 + WAL / SHM / 回滚日志（存在才计）
    func databaseBytes() -> Int64 {
        let suffix = ["", "-wal", "-shm", "-journal"]
        return suffix.reduce(Int64(0)) { total, suffix in
            total + Self.size(of: directory.appendingPathComponent(Self.databaseName + suffix))
        }
    }

    /// 备份清单：迁移备份 + 旧版损坏备份。只统计历史相关文件，不含设置、密钥与用户导出文件
    func backups() -> [Backup] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Backup? in
            let kind: BackupKind
            if name == Self.migratedJSONName || (name.hasPrefix("history.migrated-") && name.hasSuffix(".json")) {
                kind = .migrated
            } else if name.hasPrefix(Self.corruptPrefix) && name.hasSuffix(".json") {
                kind = .corrupt
            } else {
                return nil
            }
            let bytes = Self.size(of: directory.appendingPathComponent(name))
            return Backup(name: name, bytes: bytes, kind: kind)
        }
        .sorted { $0.name < $1.name }
    }

    func backupBytes() -> Int64 { backups().reduce(0) { $0 + $1.bytes } }

    /// 删除指定备份（仅供用户显式清理；不影响设置、密钥与导出文件）
    func removeBackup(named name: String) throws {
        // 只允许删历史备份，避免把传入的任意文件名落到其它文件上
        guard backups().contains(where: { $0.name == name }) else { return }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }

    /// 旧版 JSON 是否还在（升级前 / 归档失败时）
    var hasLegacyJSON: Bool { FileManager.default.fileExists(atPath: legacyJSONURL.path) }

    static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}