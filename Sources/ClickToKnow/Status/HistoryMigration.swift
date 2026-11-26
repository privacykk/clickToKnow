import Foundation

/// 历史功能当前无法使用的原因。展示在历史窗口与设置页，并给出可操作的处理入口。
enum HistoryBlockReason: Equatable, Sendable {
    /// 旧 JSON 无法解析：原件保留未动，可重试，或显式选择从空历史开始（原文件仍会备份）
    case corruptLegacyJSON(message: String)
    /// 数据库打不开 / 来自更高版本：不删除重建，也不回退到 JSON 写入
    case unreadable(message: String)
    /// 导入过程中写入失败（磁盘满、权限等）：保留旧文件，可重试
    case migrationFailed(message: String)

    var message: String {
        switch self {
        case .corruptLegacyJSON(let message), .unreadable(let message), .migrationFailed(let message):
            return message
        }
    }
}

/// 首次升级准备：把旧 `history.json` 一次性导入 SQLite，提交成功后归档旧文件。
///
/// 约定（与迁移文档一致）：
/// - 数据、「已导入」标记同事务提交；提交前中断则整体回滚，下次启动重试而不是双写；
/// - 提交后归档失败只提示，不重新导入（标记已生效）；
/// - 旧文件无法解析时保留原件并交给用户决定，绝不静默清空；
/// - 清空历史保留迁移标记，重启后不会把已删除的数据再导回来。
struct HistoryMigration: @unchecked Sendable {
    /// 准备结果：可用记录 + 需要提示的文案。需要用户处理的状态以抛出错误表达，见 `prepare` 的调用方
    struct Output: Sendable {
        var entries: [HistoryEntry] = []
        var warning: String?
    }

    /// 旧 JSON 解析失败（区别于磁盘/数据库错误，单独映射成用户可决策的状态）
    struct LegacyDecodeFailure: Error {
        let message: String
    }

    let files: HistoryFiles
    /// 归档动作（测试注入失败，覆盖「提交成功但归档失败」）
    var moveItem: (URL, URL) throws -> Void = { source, destination in
        try FileManager.default.moveItem(at: source, to: destination)
    }
    var now: () -> Date = Date.init

    /// 打开后立即调用：必要时导入旧数据，然后读回全部记录
    func prepare(database: HistoryDatabase) throws -> Output {
        var warnings: [String] = []
        let alreadyImported = try database.hasImportedLegacyJSON()

        if files.hasLegacyJSON {
            if alreadyImported {
                // 上次已提交但归档没成功：只补做归档，绝不重新导入
                if let failure = archiveLegacyJSON() { warnings.append(failure) }
            } else {
                let decoded = try decodeLegacy()
                if let dedupe = decoded.warning { warnings.append(dedupe) }
                try database.importLegacy(decoded.entries)
                if !decoded.entries.isEmpty {
                    warnings.insert("已从旧版历史导入 \(decoded.entries.count) 条记录", at: 0)
                }
                if let failure = archiveLegacyJSON() { warnings.append(failure) }
            }
        } else if !alreadyImported {
            // 没有旧文件：初始化空库并标记完成，避免以后误判成「待迁移」
            try database.importLegacy([])
        }

        return Output(
            entries: try database.all(),
            warning: warnings.isEmpty ? nil : warnings.joined(separator: "；")
        )
    }

    /// 用户选择「从空历史开始」：先把无法解析的原件改名为损坏备份（保留可抢救副本），再标记完成。
    /// 该操作只由用户显式触发，不会在启动流程里自动执行。
    func startEmptyAfterCorrupt(database: HistoryDatabase) throws -> Output {
        let destination = corruptBackupURL()
        try moveItem(files.legacyJSONURL, destination)
        try database.importLegacy([])
        return Output(
            entries: try database.all(),
            warning: "已从空历史开始；原文件已备份为 \(destination.lastPathComponent)"
        )
    }

    // MARK: - 旧文件解析与归档

    private func decodeLegacy() throws -> (entries: [HistoryEntry], warning: String?) {
        let data: Data
        do {
            data = try Data(contentsOf: files.legacyJSONURL)
        } catch {
            throw LegacyDecodeFailure(message: "无法读取旧版历史文件：\(error.localizedDescription)")
        }
        // 0 字节文件：正常的空记录，不是损坏
        if data.isEmpty { return ([], nil) }
        do {
            let decoded = try Self.decoder.decode([HistoryEntry].self, from: data)
            return Self.deduplicated(decoded)
        } catch {
            throw LegacyDecodeFailure(
                message: "旧版历史文件无法解析（\(error.localizedDescription)）。原文件未做任何修改；"
                    + "可重试，或选择从空历史开始（原文件会备份为 \(HistoryFiles.corruptPrefix)…json）。"
            )
        }
    }

    /// uuid 重复的记录只保留第一条（数组是新 → 旧，第一条即最新），并给出提示
    private static func deduplicated(_ entries: [HistoryEntry]) -> ([HistoryEntry], String?) {
        var seen = Set<UUID>()
        var unique: [HistoryEntry] = []
        unique.reserveCapacity(entries.count)
        for entry in entries where seen.insert(entry.id).inserted {
            unique.append(entry)
        }
        guard unique.count != entries.count else { return (unique, nil) }
        return (unique, "旧版历史中有 \(entries.count - unique.count) 条重复记录，已保留较新的一条")
    }

    /// 旧文件归档：成功后不再双写。返回失败提示（成功返回 nil）
    private func archiveLegacyJSON() -> String? {
        let destination = uniqueArchiveURL()
        do {
            try moveItem(files.legacyJSONURL, destination)
            Log.app.info("旧版历史已归档为 \(destination.lastPathComponent)")
            return nil
        } catch {
            Log.app.error("旧版历史归档失败：\(error.localizedDescription)")
            return "旧版历史已导入，但原文件归档失败（\(error.localizedDescription)）；"
                + "下次启动会重试归档，不会重复导入"
        }
    }

    private func uniqueArchiveURL() -> URL {
        guard FileManager.default.fileExists(atPath: files.migratedJSONURL.path) else {
            return files.migratedJSONURL
        }
        return files.directory.appendingPathComponent("history.migrated-\(Self.stamp(now())).json")
    }

    private func corruptBackupURL() -> URL {
        files.directory.appendingPathComponent("\(HistoryFiles.corruptPrefix)\(Self.stamp(now())).json")
    }

    private static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}