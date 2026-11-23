import SwiftUI

/// 设置中心页签：状态总览可据此把用户直接送到对应配置页
enum SettingsTab: Hashable {
    case status
    case llm
    case hotKey
}

/// 设置与状态中心根视图：三 Tab（状态总览 / 大模型 / 快捷键）。
/// AppStatusModel 由窗口壳经 environmentObject 注入，各 Tab 只读消费；
/// 页签选择提升到根视图，供状态总览的「去配置 / 去修改」直接跳转。
struct SettingsRootView: View {
    @State private var selection: SettingsTab = .status

    var body: some View {
        TabView(selection: $selection) {
            StatusTabView(selection: $selection)
                .tabItem { Label("状态总览", systemImage: "info.circle") }
                .tag(SettingsTab.status)
            LLMSettingsTabView()
                .tabItem { Label("大模型", systemImage: "sparkles") }
                .tag(SettingsTab.llm)
            HotKeyTabView()
                .tabItem { Label("快捷键", systemImage: "command") }
                .tag(SettingsTab.hotKey)
        }
    }
}
