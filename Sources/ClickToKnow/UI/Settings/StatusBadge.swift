import SwiftUI

/// 圆点状态徽标：ok（绿）/ bad（红）/ warn（橙）三级 + 文案，状态页与快捷键页复用。
struct StatusBadge: View {
    enum Level {
        case ok, bad, warn
    }

    let level: Level
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            Text(text)
        }
    }

    private var color: Color {
        switch level {
        case .ok: return .green
        case .bad: return .red
        case .warn: return .orange
        }
    }
}
