import AppKit
import SwiftUI

/// 历史记录（生词本）：左列表右详情的分栏布局，支持导出 CSV / Anki TSV 与清空。
/// 数据源是 HistoryStore.shared（查询成功时写入），窗口打开时重新拉取。
@MainActor
struct HistoryView: View {
    /// 本地镜像列表：窗口出现时从 HistoryStore.shared 拉取一次
    @State private var entries: [HistoryEntry] = []
    /// 左列表当前选中条目 id
    @State private var selection: HistoryEntry.ID?
    /// 操作结果提示（导出成功/失败、清空）
    @State private var notice: String?

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.term)
                        .font(.headline)
                        .lineLimit(1)
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 200)
        } detail: {
            if let entry = entries.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.term).font(.title2).bold()
                        Text(entry.source == "llm" ? "大模型 · \(entry.model ?? "")" : "系统词典")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        // LocalizedStringKey 触发 SwiftUI 内建 Markdown 渲染（加粗/列表/链接）
                        Text(LocalizedStringKey(entry.content))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                }
            } else {
                Text(entries.isEmpty ? "暂无查询记录" : "选中左侧条目查看释义")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            ToolbarItemGroup {
                Button("导出 CSV") { export(format: .csv) }
                    .disabled(entries.isEmpty)
                Button("导出 Anki") { export(format: .anki) }
                    .disabled(entries.isEmpty)
                Button("清空", role: .destructive) { clear() }
                    .disabled(entries.isEmpty)
            }
        }
        .onAppear { entries = HistoryStore.shared.entries }
    }

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

    /// 弹保存面板写出对应格式文件（结果经 notice 提示）
    private func export(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .csv
            ? HistoryStore.shared.exportCSV()
            : HistoryStore.shared.exportAnkiTSV()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            notice = "已导出 \(entries.count) 条"
        } catch {
            notice = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 清空全部历史（不可撤销，按钮已标 destructive）
    private func clear() {
        HistoryStore.shared.removeAll()
        entries = []
        selection = nil
        notice = "已清空"
    }
}
