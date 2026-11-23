import SwiftUI

/// 圆点状态徽标：ok（绿）/ bad（红）/ warn（橙）三级 + 文案，状态页与快捷键页复用。
struct StatusBadge: View {
    /// 状态等级（决定圆点颜色）
    enum Level {
        case ok, bad, warn
    }

    let level: Level
    /// 展示文案（如「已注册」「未授权」）
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
        }
    }

    /// 等级 → 颜色映射
    private var color: Color {
        switch level {
        case .ok: return .green
        case .bad: return .red
        case .warn: return .orange
        }
    }
}
