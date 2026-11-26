import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 隐私设置：查询数据、历史记录（位置 / 占用 / 保留条数 / 清理）与禁止取词的应用。
///
/// 历史占用与记录数都取自 `HistoryStore`（数据库与文件的实际状态），不写死文案；
/// 任何清理动作都先说明范围（是否包含收藏、备份），执行后刷新数字，失败时明确提示。
@MainActor
struct PrivacySettingsTabView: View {
    private let config = AppConfig.shared
    @State private var localOnly = AppConfig.shared.localDictionaryOnly
    @State private var sendsContext = AppConfig.shared.sendsQueryContext
    @State private var recordsHistory = AppConfig.shared.recordsQueryHistory
    @State private var reusesHistory = AppConfig.shared.reusesQueryHistory
    @State private var blockedApps = AppConfig.shared.customBlacklistedBundleIDs
    @State private var bundleID = ""
    /// 历史占用统计（记录数 / 数据库占用 / 备份）
    @State private var stats: HistoryStorageStats?
    /// 当前保留条数（与设置项一致；降低档位要二次确认后才写入）
    @State private var retention = AppConfig.shared.historyRetentionLimit
    /// 待确认的操作（同一时间只弹一个确认框）
    @State private var pending: Confirmation?
    /// 操作结果提示
    @State private var notice: String?
    /// 禁止取词列表的操作反馈（选中应用无法读取 Bundle ID 等）
    @State private var blacklistNotice: String?

    /// 需要二次确认的操作。用一个枚举统一驱动确认框，避免多个 confirmationDialog 互相覆盖
    private enum Confirmation: Identifiable {
        case clearAll
        case clearNonFavorites
        case removeBackups
        case reclaimSpace
        case lowerRetention(Int)

        var id: String {
            switch self {
            case .clearAll: return "clearAll"
            case .clearNonFavorites: return "clearNonFavorites"
            case .removeBackups: return "removeBackups"
            case .reclaimSpace: return "reclaimSpace"
            case .lowerRetention(let limit): return "lower-\(limit)"
            }
        }
    }

    private var candidate: String { bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section("查询数据") {
                Toggle("查询仅使用 macOS 系统词典", isOn: $localOnly)
                    .onChange(of: localOnly) { config.localDictionaryOnly = $0 }
                Toggle("向大模型发送选区前后文", isOn: $sendsContext)
                    .disabled(localOnly)
                    .onChange(of: sendsContext) { config.sendsQueryContext = $0 }
                Text("关闭前后文后，大模型查询仍会发送选中的文字。手动测试连接和拉取模型仍会访问配置的端点。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            historySection
            blacklistSection
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshStats)
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in
            refreshStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didFailToSaveNotification)) { _ in
            if let error = HistoryStore.shared.lastSaveError {
                notice = error
                refreshStats()
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(confirmationActionTitle(action), role: .destructive) {
                perform(action)
                pending = nil
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    // MARK: - 历史记录

    private var historySection: some View {
        Section("历史记录") {
            Toggle("保存查询历史", isOn: $recordsHistory)
                .onChange(of: recordsHistory) { config.recordsQueryHistory = $0 }
            Toggle("优先复用本地历史", isOn: $reusesHistory)
                .disabled(!recordsHistory)
                .onChange(of: reusesHistory) { config.reusesQueryHistory = $0 }
            Text("条件完全相同（词条、前后文、来源、端点、模型与释义模板）的查询直接显示历史释义，不再请求网络；"
                 + "关闭保存历史时该项不生效，但不会删除已有记录。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("历史只保存在这台 Mac：\(HistoryStore.shared.files.directory.path)")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("使用在线模型查询时，选中的文字仍会随请求发送给所配置的服务；历史数据库不做应用级加密。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let stats {
                LabeledContent("记录", value: "\(stats.recordCount) 条")
                LabeledContent("数据库占用", value: Self.bytes(stats.databaseBytes))
                if stats.backupBytes > 0 {
                    LabeledContent("备份占用", value: Self.bytes(stats.backupBytes))
                }
                if stats.legacyJSONPresent {
                    Text("旧版 history.json 尚未迁移完成，迁移前会一直保留。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("记录", value: "统计中…")
            }

            Picker("保留条数", selection: retentionBinding) {
                ForEach(HistoryRetention.options, id: \.self) { option in
                    Text(option == HistoryRetention.defaultLimit ? "\(option)（默认）" : "\(option)").tag(option)
                }
            }
            Text("超出上限时自动淘汰最旧的非收藏记录；收藏不会被自动删除，收藏本身超过上限时记录数可以超出上限。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("清空历史记录…", role: .destructive) { pending = .clearAll }
                    .disabled((stats?.recordCount ?? 0) == 0)
                Button("仅清理非收藏…") { pending = .clearNonFavorites }
                    .disabled((stats?.recordCount ?? 0) == 0)
            }
            HStack(spacing: 12) {
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.files.directory])
                }
                Button("回收磁盘空间…") { pending = .reclaimSpace }
                if (stats?.backupBytes ?? 0) > 0 {
                    Button("清理备份…", role: .destructive) { pending = .removeBackups }
                }
            }
            Text("清空记录后数据库文件不一定变小（空闲页会留给后续记录复用）。需要释放磁盘时用「回收磁盘空间」。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 选择保留条数：升高立即生效，降低先确认预计删除条数
    private var retentionBinding: Binding<Int> {
        Binding(
            get: { retention },
            set: { newValue in
                guard newValue != retention else { return }
                if newValue < retention {
                    pending = .lowerRetention(newValue)
                } else {
                    applyRetention(newValue)
                }
            }
        )
    }

    private func applyRetention(_ limit: Int) {
        config.historyRetentionLimit = limit
        retention = limit
        let removed = HistoryStore.shared.applyRetentionLimit(limit)
        refreshStats()
        notice = removed > 0
            ? "已改为保留 \(limit) 条，清理了 \(removed) 条最旧的未收藏记录"
            : "已改为保留 \(limit) 条"
    }

    private func refreshStats() {
        stats = HistoryStore.shared.storageStats()
        retention = config.historyRetentionLimit
    }

    // MARK: - 确认框文案与执行

    private var confirmationTitle: String {
        switch pending {
        case .clearAll: return "清空全部历史记录？"
        case .clearNonFavorites: return "只清理未收藏的记录？"
        case .removeBackups: return "删除历史备份？"
        case .reclaimSpace: return "回收磁盘空间？"
        case .lowerRetention(let limit): return "把保留条数降到 \(limit) 条？"
        case .none: return ""
        }
    }

    private func confirmationActionTitle(_ confirmation: Confirmation) -> String {
        switch confirmation {
        case .clearAll: return "清空全部记录"
        case .clearNonFavorites: return "清理未收藏记录"
        case .removeBackups: return "删除备份"
        case .reclaimSpace: return "回收磁盘空间"
        case .lowerRetention: return "立即清理并应用"
        }
    }

    private func confirmationMessage(_ confirmation: Confirmation) -> String {
        let count = stats?.recordCount ?? HistoryStore.shared.entries.count
        switch confirmation {
        case .clearAll:
            return "将删除全部 \(count) 条记录，收藏也会删除，无法恢复；已导出的文件不受影响。"
                + "迁移备份与损坏备份不会一起删除，可在「清理备份」里单独处理。"
        case .clearNonFavorites:
            let favorites = HistoryStore.shared.entries.filter(\.isFavorite).count
            return "将删除 \(count - favorites) 条未收藏记录，保留 \(favorites) 条收藏。"
        case .removeBackups:
            return "将删除迁移备份与损坏备份（共 \(Self.bytes(stats?.backupBytes ?? 0))），"
                + "删除后无法再用它们恢复升级前的历史。不影响设置、密钥与导出文件。"
        case .reclaimSpace:
            return "记录不会变化，只是让数据库文件把空闲页归还给系统。数据量大时可能需要几秒，期间仍可正常查询。"
        case .lowerRetention(let limit):
            let deleatable = HistoryStore.shared.trimPreview(for: limit)
            return "将立即删除最旧的 \(deleatable) 条未收藏记录；收藏不会被自动删除，"
                + "若收藏本身超过 \(limit) 条，记录总数会高于上限。"
        }
    }

    private func perform(_ confirmation: Confirmation) {
        switch confirmation {
        case .clearAll:
            let count = stats?.recordCount ?? 0
            HistoryStore.shared.removeAll()
            notice = "已清空 \(count) 条记录"
            refreshStats()
        case .clearNonFavorites:
            let removed = HistoryStore.shared.removeNonFavorites()
            notice = "已清理 \(removed) 条未收藏记录"
            refreshStats()
        case .removeBackups:
            let freed = HistoryStore.shared.removeBackups()
            notice = "已删除备份，释放 \(Self.bytes(freed))"
            refreshStats()
        case .reclaimSpace:
            notice = "正在回收磁盘空间…"
            HistoryStore.shared.reclaimDiskSpace { result in
                switch result {
                case .success(let updated):
                    stats = updated
                    notice = "已回收磁盘空间，当前占用 \(Self.bytes(updated.databaseBytes))"
                case .failure(let error):
                    // 失败要如实说明「没有释放」，不能显示成已清理
                    notice = "回收失败：\(error.localizedDescription)"
                    refreshStats()
                }
            }
        case .lowerRetention(let limit):
            applyRetention(limit)
        }
    }

    // MARK: - 禁止取词的应用

    private var blacklistSection: some View {
        Section("禁止取词的应用") {
            HStack {
                TextField("应用 Bundle ID", text: $bundleID, prompt: Text("com.example.app"))
                    .onSubmit(addBundle)
                Button("添加", action: addBundle)
                    .disabled(!canAddBundle)
            }
            Button("选择应用程序…", action: chooseApplications)
                .help("从「应用程序」目录或其他位置选择要禁止取词的应用，按 Bundle ID 添加")
            ForEach(blockedApps, id: \.self) { id in
                let label = AppBundleInfo.label(forBundleID: id)
                LabeledContent {
                    Button("移除") {
                        config.customBlacklistedBundleIDs.removeAll { $0 == id }
                        blockedApps = config.customBlacklistedBundleIDs
                    }
                    .accessibilityLabel("移除 \(label.title)")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label.title)
                        if let subtitle = label.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if let blacklistNotice {
                Text(blacklistNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("内置密码管理类应用始终禁止取词；规则按 Bundle ID 匹配，应用移动位置后仍然有效。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var canAddBundle: Bool {
        let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
            && !config.blacklistedBundleIDs.contains(candidate)
    }

    /// 打开系统文件选择器添加应用：读得到 Bundle ID 才加入，取消或读不到都不改动列表
    private func chooseApplications() {
        blacklistNotice = nil
        let panel = NSOpenPanel()
        panel.title = "选择要禁止取词的应用"
        panel.message = "选择后按应用的 Bundle ID 添加规则，规则立即生效。"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        var current = config.customBlacklistedBundleIDs
        var added = 0
        var duplicates = 0
        var unreadable: [String] = []
        for url in panel.urls {
            guard let identifier = AppBundleInfo.bundleID(at: url) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            if config.blacklistedBundleIDs.contains(identifier) {
                duplicates += 1
                continue
            }
            current.append(identifier)
            added += 1
        }
        config.customBlacklistedBundleIDs = current
        blockedApps = config.customBlacklistedBundleIDs

        var parts: [String] = []
        if added > 0 { parts.append("已添加 \(added) 个应用") }
        if duplicates > 0 { parts.append("\(duplicates) 个已在列表中") }
        if !unreadable.isEmpty {
            parts.append("无法读取 Bundle ID：\(unreadable.joined(separator: "、"))（未添加）")
        }
        blacklistNotice = parts.isEmpty ? "未添加任何应用" : parts.joined(separator: "；")
    }

    private func addBundle() {
        guard canAddBundle else { return }
        config.customBlacklistedBundleIDs.append(candidate)
        blockedApps = config.customBlacklistedBundleIDs
        bundleID = ""
    }

    /// 字节数的人类可读形式（0 也显示 0 KB，避免用户以为统计失败）
    private static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(value, 0))
    }
}