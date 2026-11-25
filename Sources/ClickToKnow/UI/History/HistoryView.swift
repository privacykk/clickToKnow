import AppKit
import SwiftUI

/// 历史记录（生词本）：左侧「搜索 + 来源筛选 + 按日分组列表」，右侧完整释义详情。
/// 支持单条删除、清空（二次确认）与按当前筛选导出 CSV / Anki TSV；
/// 数据源是 HistoryStore.shared，窗口打开时拉取，并订阅变更通知实时刷新。
@MainActor
struct HistoryView: View {
    /// 全量记录（新 → 旧），筛选只作用于展示层
    @State private var entries: [HistoryEntry] = []
    /// 左列表当前选中条目 id
    @State private var selection: HistoryEntry.ID?
    /// 搜索关键词（词条或释义内容）
    @State private var query = ""
    /// 来源筛选（全部 / 大模型 / 系统词典）
    @State private var sourceFilter: HistoryFilter.Source = .all
    @State private var favoritesOnly = false
    /// 清空确认弹窗开关
    @State private var pendingClear = false
    /// 启动加载时的问题（如历史文件损坏已备份）：顶部常驻提示，避免用户以为数据莫名消失
    @State private var loadWarning: String?
    /// 底部状态栏的短提示（导出 / 删除 / 清空结果）
    @State private var notice: String?
    /// 提示是否为失败态（决定文字颜色）
    @State private var noticeIsError = false
    /// 提示自动消失任务（连续操作时取消重排）
    @State private var noticeTask: Task<Void, Never>?
    /// 搜索框焦点（⌘F 聚焦）
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 400)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar { toolbarContent }
        .confirmationDialog("清空全部历史记录？", isPresented: $pendingClear) {
            Button("清空 \(entries.count) 条记录", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复；已经导出的文件不受影响。")
        }
        .background(shortcutCatcher)
        .onAppear { reload() }
        .onChange(of: filter) { _ in reconcileSelection() }
        .onChange(of: favoritesOnly) { _ in reconcileSelection() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in
            reload()
        }
        .onDisappear { noticeTask?.cancel() }
    }

    // MARK: - 左侧列表

    /// 侧栏：搜索框 + 来源胶囊 + 分组列表 + 底部计数
    private var sidebar: some View {
        VStack(spacing: 0) {
            if let loadWarning {
                warningBanner(loadWarning)
            }
            VStack(spacing: 8) {
                searchField
                filterBar
                Toggle("仅显示收藏", isOn: $favoritesOnly)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            if visibleEntries.isEmpty {
                emptySidebar
            } else {
                entryList
            }

            footer
        }
    }

    /// 顶部告警横幅：只在启动加载出问题时出现（如原文件损坏已备份），不占常驻空间
    private func warningBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                loadWarning = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .help("已知悉，隐藏提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    /// 自绘搜索框：系统 .searchable 依赖工具栏，这里在侧栏内固定展示更稳定
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("搜索词条或释义", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
    }

    /// 来源胶囊筛选条
    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(HistoryFilter.Source.allCases) { source in
                filterChip(source)
            }
            Spacer(minLength: 0)
            if hasActiveFilters {
                Button("重置") { resetFilter() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("清除关键词与来源筛选")
            }
        }
    }

    /// 单个来源胶囊：选中态用强调色浅底突出
    private func filterChip(_ source: HistoryFilter.Source) -> some View {
        let isActive = sourceFilter == source
        return Button {
            sourceFilter = source
        } label: {
            Text(source.title)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    isActive ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    /// 按天分组后的列表（新 → 旧，分组标题为 今天 / 昨天 / 具体日期）
    private var entryList: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        row(entry)
                    }
                } header: {
                    Text(section.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            guard let entry = selectedEntry else { return }
            delete(entry)
        }
    }

    /// 单行：词条 + 时间、来源与模型、释义首行预览
    private func row(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.term)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if entry.isFavorite {
                    Image(systemName: "star.fill")
                        .accessibilityLabel("已收藏")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 4) {
                Image(systemName: sourceIcon(entry))
                    .font(.system(size: 9))
                    .foregroundStyle(sourceColor(entry))
                Text(sourceLabel(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            let preview = previewText(entry)
            if !preview.isEmpty {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .tag(entry.id)
        .contextMenu {
            Button("复制释义") { copy(entry) }
            Button(entry.isFavorite ? "取消收藏" : "收藏") { HistoryStore.shared.toggleFavorite(id: entry.id) }
            Divider()
            Button("删除", role: .destructive) { delete(entry) }
        }
    }

    /// 无记录 / 无匹配时的侧栏空态
    private var emptySidebar: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle" : "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(hasActiveFilters ? "没有匹配的记录" : "还没有查询记录")
                .font(.callout)
                .foregroundStyle(.secondary)
            if hasActiveFilters {
                Button("清除筛选") { resetFilter() }
                    .buttonStyle(.link)
            } else {
                Text("选中文字后按快捷键查询，结果会自动收进这里。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 底部状态栏：总数 / 筛选计数 + 操作反馈
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(summaryText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let notice {
                    Text(notice)
                        .font(.caption2)
                        .foregroundStyle(noticeIsError ? Color.red : Color.green)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    // MARK: - 右侧详情

    /// 详情区：有选中条目展示全文，否则给出引导
    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            detailView(entry)
        } else {
            placeholder
        }
    }

    /// 详情正文：标题 + 元信息胶囊 + Markdown 排版内容
    private func detailView(_ entry: HistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.term)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .textSelection(.enabled)
                    Spacer(minLength: 12)
                    Button {
                        copy(entry)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .help("复制释义正文")
                    Button(role: .destructive) {
                        delete(entry)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .help("删除这条记录")
                }

                HStack(spacing: 8) {
                    metaChip(
                        systemImage: sourceIcon(entry),
                        text: sourceLabel(entry),
                        color: sourceColor(entry)
                    )
                    metaChip(
                        systemImage: "clock",
                        text: entry.date.formatted(date: .abbreviated, time: .shortened),
                        color: .secondary
                    )
                }

                Divider()
                MarkdownText(markdown: entry.content)
            }
            .padding(24)
        }
    }

    /// 元信息胶囊（来源 / 时间）
    private func metaChip(systemImage: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    /// 未选中条目时的占位页
    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.quote")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(entries.isEmpty ? "查询结果会收进这里" : "选中左侧条目查看完整释义")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 工具栏

    /// 导出菜单 + 清空（清空需二次确认）
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Button("CSV（表格 / 通用）") { export(format: .csv) }
                Button("Anki TSV（导入卡片）") { export(format: .anki) }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(visibleEntries.isEmpty)
            .help("按当前筛选导出，所见即所得")

            Button(role: .destructive) {
                pendingClear = true
            } label: {
                Label("清空", systemImage: "trash")
            }
            .disabled(entries.isEmpty)
            .help("清空全部历史记录（需确认）")
        }
    }

    /// ⌘F 聚焦搜索框（隐藏按钮承接快捷键）
    private var shortcutCatcher: some View {
        Button("") { searchFocused = true }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    // MARK: - 筛选与数据

    /// 当前筛选条件
    private var filter: HistoryFilter {
        HistoryFilter(query: query, source: sourceFilter)
    }

    private var hasActiveFilters: Bool { filter.isActive || favoritesOnly }

    /// 筛选后的记录（保持新 → 旧顺序）
    private var visibleEntries: [HistoryEntry] {
        filter.apply(to: favoritesOnly ? entries.filter(\.isFavorite) : entries)
    }

    /// 当前选中条目（全量里找，避免筛选瞬间详情闪烁）
    private var selectedEntry: HistoryEntry? {
        guard let selection else { return nil }
        return entries.first { $0.id == selection }
    }

    /// 侧栏分组：按开始日期倒序，标题做「今天 / 昨天 / 日期」的人性化处理
    private var sections: [DaySection] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [HistoryEntry]] = [:]
        for entry in visibleEntries {
            let day = calendar.startOfDay(for: entry.date)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        return order.map { day in
            DaySection(id: day, title: dayTitle(day), entries: buckets[day] ?? [])
        }
    }

    /// 底部计数：无筛选时只显示总数
    private var summaryText: String {
        hasActiveFilters
            ? "共 \(entries.count) 条 · 筛选后 \(visibleEntries.count) 条"
            : "共 \(entries.count) 条记录"
    }

    /// 分组标题
    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return day.formatted(.dateTime.year().month().day())
    }

    /// 从 HistoryStore 重新拉取，并尽量保留当前选中项
    private func reload() {
        entries = HistoryStore.shared.entries
        loadWarning = HistoryStore.shared.loadWarning
        if let selection, visibleEntries.contains(where: { $0.id == selection }) {
            return
        }
        selection = visibleEntries.first?.id
    }

    /// 筛选变化后，若选中项不在结果里则自动落到首条，避免详情与列表脱节
    private func reconcileSelection() {
        guard let selection, visibleEntries.contains(where: { $0.id == selection }) else {
            self.selection = visibleEntries.first?.id
            return
        }
    }

    /// 清除关键词与来源筛选
    private func resetFilter() {
        query = ""
        sourceFilter = .all
        favoritesOnly = false
    }

    // MARK: - 行为

    /// 导出格式：CSV 通用 / Anki TSV 可直接导入 Anki
    private enum ExportFormat {
        case csv, anki

        /// 保存面板默认文件名
        var fileName: String {
            switch self {
            case .csv: return "clicktoknow-history.csv"
            case .anki: return "clicktoknow-anki.txt"
            }
        }
    }

    /// 弹保存面板导出当前筛选结果（结果经底部提示反馈）
    private func export(format: ExportFormat) {
        let source = visibleEntries
        guard !source.isEmpty else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = format == .csv
            ? HistoryStore.shared.exportCSV(source)
            : HistoryStore.shared.exportAnkiTSV(source)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showNotice("已导出 \(source.count) 条")
        } catch {
            showNotice("导出失败：\(error.localizedDescription)", isError: true)
        }
    }

    /// 删除单条（列表会经变更通知自动刷新，选中项顺延到首条）
    private func delete(_ entry: HistoryEntry) {
        HistoryStore.shared.remove(id: entry.id)
        showNotice("已删除「\(entry.term)」")
    }

    /// 清空全部（已二次确认）
    private func clearAll() {
        let count = entries.count
        HistoryStore.shared.removeAll()
        selection = nil
        showNotice("已清空 \(count) 条记录")
    }

    /// 复制释义正文到剪贴板
    private func copy(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.content, forType: .string)
        showNotice("已复制释义")
    }

    /// 底部短提示，3 秒后自动消失
    private func showNotice(_ text: String, isError: Bool = false) {
        notice = text
        noticeIsError = isError
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    // MARK: - 展示辅助

    /// 是否大模型来源
    private func isLLM(_ entry: HistoryEntry) -> Bool {
        entry.source == Interpretation.Source.llm.rawValue
    }

    private func sourceIcon(_ entry: HistoryEntry) -> String {
        isLLM(entry) ? "sparkles" : "character.book.closed"
    }

    /// 来源文案：大模型附带模型名，系统词典固定文案
    private func sourceLabel(_ entry: HistoryEntry) -> String {
        guard isLLM(entry) else { return "系统词典" }
        guard let model = entry.model, !model.isEmpty else { return "大模型" }
        return "大模型 · \(model)"
    }

    private func sourceColor(_ entry: HistoryEntry) -> Color {
        isLLM(entry) ? .accentColor : .secondary
    }

    /// 列表预览：去掉 Markdown 记号后取第一行非空内容
    private func previewText(_ entry: HistoryEntry) -> String {
        let cleaned = entry.content
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        return cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// 按日分组的分组模型（id 用当天开始时刻，稳定且可比较）
private struct DaySection: Identifiable {
    let id: Date
    let title: String
    let entries: [HistoryEntry]
}
