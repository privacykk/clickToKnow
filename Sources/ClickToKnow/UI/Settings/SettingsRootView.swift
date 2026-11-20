import SwiftUI

/// 设置与状态中心根视图：三 Tab（状态总览 / 大模型 / 快捷键）。
/// AppStatusModel 由窗口壳经 environmentObject 注入，各 Tab 只读消费。
struct SettingsRootView: View {
    var body: some View {
        TabView {
            StatusTabView()
                .tabItem { Label("状态总览", systemImage: "info.circle") }
            LLMSettingsTabView()
                .tabItem { Label("大模型", systemImage: "sparkles") }
            HotKeyTabView()
                .tabItem { Label("快捷键", systemImage: "command") }
        }
    }
}
