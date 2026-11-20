# Tasks Document

> 执行计划：4 个阶段、14 个任务，按依赖顺序排列；同阶段内无依赖的任务可并行。
> 每完成一个阶段执行一次 `swift build` 回归；阶段 D 收尾执行 `swift test` + 手动验收清单。
> 需求编号对应 `requirements.md`（R1 状态页 / R2 大模型 / R3 快捷键 / R4 菜单 / NFR 非功能）。

## 阶段 A：基础层（纯逻辑，无 UI 依赖）

- [x] 1. 新建 HotKeyBinding 模型与 CarbonKeyTranslator
  - File: Sources/ClickToKnow/Selection/CarbonKeyTranslator.swift
  - 定义 `HotKeyBinding`（keyCode + carbonModifiers + displayString 计算属性）
  - 实现 keyCode→键名映射表（kVK_ANSI_* 常用约 80 项，未知回退 `KeyCode(n)`）、修饰键按 ⌃⌥⇧⌘ 排序拼接
  - 实现 `carbonModifiers(from: NSEvent.ModifierFlags)`（.command→cmdKey=256、.shift→512、.option→2048、.control→4096）与 `hasRequiredModifier`（含 ⌘/⌥/⌃ 之一，仅 ⇧ 不算）
  - `defaultBinding` = ⌥⌘K（kVK_ANSI_K=40, cmdKey|optionKey）
  - Purpose: 快捷键可读化与录制的公共基础，R3 全部依赖它
  - _Leverage: Selection/GlobalHotKey.swift 中已 import 的 Carbon.HIToolbox 常量_
  - _Requirements: 3.1, 3.2, NFR-Modularity_
  - _Prompt: Role: macOS 系统编程工程师 | Task: 按 design.md「CarbonKeyTranslator」接口实现键码翻译与修饰键映射，含默认绑定常量 | Restrictions: 纯函数无副作用；不引入第三方依赖；映射表覆盖字母数字/F 区/常用标点 | Success: displayString 对默认绑定输出 "⌥⌘K"，编译通过_

- [x] 2. 新建 KeychainSecretStore
  - File: Sources/ClickToKnow/Config/KeychainSecretStore.swift
  - `kSecClassGenericPassword`，service=`ClickToKnow`，account 默认 `apiKey`
  - save 先查后写（存在→SecItemUpdate，避免 errSecDuplicateItem）；load/delete 幂等
  - `isAvailable` 探测一次并缓存；所有失败返回 false/nil 并 NSLog（**日志不得含密钥值**）
  - Purpose: 密钥安全存储层，可整体回退（R2.5/R2.7）
  - _Leverage: 无（新文件，Security.framework）_
  - _Requirements: 2.5, 2.7, NFR-Security_
  - _Prompt: Role: macOS 安全工程师 | Task: 实现钥匙串通用密码的 save/load/delete/isAvailable，接口见 design.md | Restrictions: 不抛崩溃；OSStatus 错误全部消化为返回值；日志脱敏 | Success: round-trip 手测通过，重复 save 覆盖不报错_

- [x] 3. 扩展 AppConfig：快捷键持久化 + 密钥解析链 + 掩码 + 通知 + 迁移
  - File: Sources/ClickToKnow/Config/AppConfig.swift (modify existing)
  - 新增 `hotKeyBinding` get/set（UserDefaults 键 `hotKeyKeyCode`/`hotKeyModifiers`，默认取 `CarbonKeyTranslator.defaultBinding`；setter 持久化后 post `.ctkHotKeyBindingChanged`）
  - `apiKey` getter 解析链改为 环境变量 → 钥匙串 → UserDefaults 遗留；新增 `apiKeySource`、`maskedAPIKey`（前4后4，≤8 全掩码）、`setAPIKey`（空串=清除两处；优先钥匙串，失败回退 UserDefaults）、`migrateLegacyKeyIfNeeded()`（幂等，以钥匙串为准）
  - 保留 `baseURL/model/hasLLMConfig/apiKeyFromEnvironment` 现有语义不变
  - Purpose: 配置单一入口，R1/R2/R3 的数据源
  - _Leverage: 任务 1 的 HotKeyBinding、任务 2 的 KeychainSecretStore；现有 suite UserDefaults_
  - _Requirements: 1.1, 2.4, 2.5, 2.6, 2.8, 3.3, 3.5_
  - _Prompt: Role: Swift 后端工程师 | Task: 按 design.md「AppConfig（扩展）」接口改造，保持既有键名与行为兼容 | Restrictions: 不破坏 ProviderFactory 按次读取即生效的机制；迁移幂等；线程安全沿用现状 | Success: 编译通过，旧配置升级后仍可读取_

- [x] 4. 新建 ProviderPresets
  - File: Sources/ClickToKnow/Config/ProviderPresets.swift
  - 按 design.md 预设表实现 7 项（DeepSeek/通义千问/月之暗面/智谱/OpenAI/Ollama/自定义），含 `matching(baseURL:)` 反查
  - Purpose: 大模型页预设下拉数据源（R2.1）
  - _Requirements: 2.1_
  - _Prompt: Role: Swift 工程师 | Task: 实现静态预设数据与反查函数 | Restrictions: 纯数据无逻辑分支；Ollama apiKeyOptional=true | Success: 编译通过，反查命中/未命中路径正确_

- [x] 5. OpenAICompatProvider.ping() + LLMConnectionTester
  - File: Sources/ClickToKnow/Interpretation/OpenAICompatProvider.swift (modify), Sources/ClickToKnow/Interpretation/LLMConnectionTester.swift (new)
  - `ping()`：POST chat/completions，body `{model, max_tokens:1, messages:[{user:"hi"}]}`，复用 `chatCompletionsURL`/session/`networkHint`/HTTP 片段截取，成功返回耗时
  - `LLMConnectionTester.test(baseURL:apiKey:model:)`：apiKey 为空时自动代入 `AppConfig.shared.apiKey`（覆盖 env/钥匙串场景）；输出 `.success(latencyMs)` / `.failure(分类中文文案)`（401→密钥无效、404→模型或路径不存在、URLError→networkHint 口径）
  - session 保持可注入（沿用 init 的 session 参数缝），供测试 mock
  - Purpose: 保存前验证配置（R2.3）
  - _Leverage: OpenAICompatProvider 现有错误翻译与 URL 拼装_
  - _Requirements: 2.3, NFR-Performance/Security_
  - _Prompt: Role: 网络层工程师 | Task: 实现最小连通探测与面向 UI 的测试门面 | Restrictions: 不改动 interpret() 行为；日志与返回值不含 Authorization；计时用 ContinuousClock/Date | Success: 对真实 DeepSeek 端点手测成功返回耗时，错误 key 返回 401 分类文案_

## 阶段 B：运行时接线

- [x] 6. SelectionMonitor 支持配置化热键与热重注册
  - File: Sources/ClickToKnow/Selection/SelectionMonitor.swift (modify existing)
  - `start()` 改读 `AppConfig.shared.hotKeyBinding`；内部持 `currentBinding`
  - 新增 `isHotKeyRegistered`（透传 GlobalHotKey.isRegistered）与 `reloadHotKey(with:) -> Bool`（试注册失败自动回滚原绑定并返回 false）
  - Purpose: R3.3/R3.4 的执行端；替换硬编码 ⌥⌘K
  - _Leverage: GlobalHotKey.register 已含 unregister 的幂等语义_
  - _Requirements: 3.3, 3.4, 3.5_
  - _Prompt: Role: macOS 工程师 | Task: 按 design.md「SelectionMonitor（扩展）」改造注册来源并实现试注册-回滚 | Restrictions: @MainActor 语义不变；抓词流程零改动 | Success: 改配置后重载即生效，占用键回滚后旧键仍可用_

- [x] 7. 新建 AppStatusModel + 提取 SystemSettingsOpener
  - File: Sources/ClickToKnow/Status/AppStatusModel.swift (new), Sources/ClickToKnow/App/SystemSettingsOpener.swift (new, 从 StatusBarController 提取)
  - `@MainActor final class AppStatusModel: ObservableObject`，接口见 design.md：AX 权限 1s Timer 轮询（start/stop/refresh）、热键绑定与注册状态（读 weak selectionMonitor + AppConfig）、LLM 摘要（hasLLMConfig/activeModel/keySource/maskedKey）、appVersion 常量、executablePath（realpath argv0）
  - `SystemSettingsOpener.openAccessibility()`：`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`
  - Purpose: SwiftUI 与菜单栏的共同状态源（R1）
  - _Leverage: StatusBarController 现有 openAccessibilitySettings 逻辑_
  - _Requirements: 1.1, 1.3, 1.4, 1.5, 4.1_
  - _Prompt: Role: Swift 状态管理工程师 | Task: 实现 ObservableObject 状态聚合与轮询生命周期管理 | Restrictions: Timer weak self 防泄漏；stopMonitoring 幂等；不 import SwiftUI | Success: 轮询启停正确，refresh 幂等_

- [x] 8. AppDelegate 装配 + StatusBarController 动态菜单
  - File: Sources/ClickToKnow/App/AppDelegate.swift (modify), Sources/ClickToKnow/App/StatusBarController.swift (modify)
  - AppDelegate：创建持有 AppStatusModel 并注入 selectionMonitor；启动调 `migrateLegacyKeyIfNeeded()`；订阅 `.ctkHotKeyBindingChanged` → refresh + NSLog
  - StatusBarController：改 `init(statusModel:)`；实现 `NSMenuDelegate.menuWillOpen` 实时刷新两条目——「快捷键：<displayString>（先选中文字）」与「辅助功能权限：已授权 ✓ / 未授权 — 去授权」（后者点击直达系统设置）；「设置…」打开新窗口（任务 9 完成前先指向旧控制器占位，任务 9 收口）
  - Purpose: R4 菜单整合 + 迁移入口
  - _Leverage: 任务 7 的 AppStatusModel/SystemSettingsOpener_
  - _Requirements: 2.6, 4.1, 4.2, 3.6_
  - _Prompt: Role: AppKit 工程师 | Task: 装配状态模型并动态化菜单条目 | Restrictions: 菜单构建仍一次性，仅 title/action 随 menuWillOpen 更新；不动划词主流程 | Success: 改绑定/授权后展开菜单即见最新状态_

## 阶段 C：UI 层（SwiftUI，依赖阶段 A/B）

- [x] 9. 重写 SettingsWindowController 壳 + SettingsRootView + StatusBadge
  - File: Sources/ClickToKnow/App/SettingsWindowController.swift (rewrite), Sources/ClickToKnow/UI/Settings/SettingsRootView.swift (new), Sources/ClickToKnow/UI/Settings/StatusBadge.swift (new)
  - NSWindow 560×520、[.titled,.closable]、isReleasedWhenClosed=false、center；contentViewController=NSHostingController(rootView: SettingsRootView(statusModel:))；showWindow 时 refresh()；windowDidBecomeKey→startMonitoring、windowWillClose→stopMonitoring
  - SettingsRootView：TabView 三页（状态总览/大模型/快捷键），`.environmentObject(statusModel)`
  - StatusBadge：ok/bad/warn 三级圆点+文案复用组件
  - Purpose: 新窗口骨架，后续 Tab 挂载点
  - _Leverage: 现有 SettingsWindowController 的懒创建复用模式（StatusBarController 持有）_
  - _Requirements: 4.2, NFR-Usability_
  - _Prompt: Role: SwiftUI+AppKit 混合工程师 | Task: 用 NSHostingView 重建窗口壳并搭 TabView 根视图 | Restrictions: 仅用 macOS 13 可用 API；窗口尺寸固定 | Success: swift build 通过，三 Tab 可切换（内容占位）_

- [x] 10. StatusTabView 状态总览
  - File: Sources/ClickToKnow/UI/Settings/StatusTabView.swift (new)
  - Form+Section 布局（权限/快捷键/释义/运行时四组，见 design.md 草图）；权限行 StatusBadge + [打开系统设置]（未授权时）+ [刷新]；权限行下附「已授权仍无效请重启」说明；密钥行显示 maskedKey+来源文案（环境来源合并显示「环境变量 / .env」）；钥匙串回退时 warn 徽标
  - `.onAppear { statusModel.startMonitoring() }` / `.onDisappear { stopMonitoring() }`（与窗口级双保险）
  - Purpose: R1 全部验收项
  - _Leverage: AppStatusModel、StatusBadge、SystemSettingsOpener_
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 2.4_
  - _Prompt: Role: SwiftUI 工程师 | Task: 实现状态总览页，数据一律来自 environmentObject | Restrictions: 视图内不做业务计算；不直接调 SelectionMonitor | Success: 授权切换 1s 内反映，离开 Tab 轮询停止_

- [x] 11. LLMSettingsTabView 大模型配置
  - File: Sources/ClickToKnow/UI/Settings/LLMSettingsTabView.swift (new)
  - 预设 Picker（选中填充 baseURL/推荐模型；`ProviderPresets.matching` 反查已存配置回显）；Base URL TextField；API Key SecureField（env/钥匙串已有密钥时禁用输入并显示掩码+来源，提供 [清除已存密钥]）；Model TextField + 推荐模型 chips；[测试连接]（LLMTestState 四态内联展示：转圈/绿成功+ms/红失败分类）；[保存]（校验 http(s):// 前缀，`setAPIKey`+baseURL+model 写入；成功提示「已保存，立即生效」）
  - Purpose: R2 全部验收项
  - _Leverage: 任务 3/4/5 的 AppConfig.setAPIKey、ProviderPresets、LLMConnectionTester_
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.8, NFR-Usability_
  - _Prompt: Role: SwiftUI 工程师 | Task: 实现大模型配置页四态测试与保存流 | Restrictions: 表单为本地 @State，保存才落盘；密钥不回显明文；测试用表单当前值 | Success: 预设一键填充、测试成功/失败文案正确、保存后划词即用新配置_

- [x] 12. HotKeyTabView + HotKeyRecorderField
  - File: Sources/ClickToKnow/UI/Settings/HotKeyTabView.swift (new), Sources/ClickToKnow/UI/Settings/HotKeyRecorderField.swift (new)
  - RecorderField：NSViewRepresentable 包自定义 NSView（acceptsFirstResponder、keyDown 捕获 keyCode+flags→CarbonKeyTranslator 映射、Esc 取消、焦点高亮边框；点击时 window.makeFirstResponder）
  - Tab 视图：当前绑定大字 + 注册状态徽标；捕获后流程按 design.md 时序图——`hasRequiredModifier` 校验 → `selectionMonitor.reloadHotKey(with:)` 试注册 → 成功才 `AppConfig.hotKeyBinding = `（持久化+发通知）；失败红字「注册失败，可能被占用」；[恢复默认 ⌥⌘K] 走同一流程
  - Purpose: R3 全部验收项
  - _Leverage: 任务 1/6 的 CarbonKeyTranslator、SelectionMonitor.reloadHotKey_
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.6_
  - _Prompt: Role: SwiftUI+Carbon 混合工程师 | Task: 实现按键录制控件与试注册-回滚-持久化流程 | Restrictions: 试注册先行，失败不落盘；纯 ⇧ 或无修饰键拒绝 | Success: 录制 ⌃⌥J 后菜单与划词即时生效，重启保留；占用键回滚_

## 阶段 D：验证与收尾

- [x] 13. 测试 target 与用例
  - File: Package.swift (modify, 加 testTarget), Tests/ClickToKnowTests/CarbonKeyTranslatorTests.swift, KeyMaskingTests.swift, ProviderPresetsTests.swift, AppConfigHotKeyTests.swift, LLMConnectionTesterTests.swift (new)
  - 单测范围见 design.md「Testing Strategy」：翻译/映射/掩码/预设反查/绑定持久化 round-trip（独立 suite 防污染）；LLMConnectionTester 用 URLProtocol mock 覆盖 2xx/401/404/超时/不可达
  - Purpose: 纯逻辑回归保障（项目首个 test target）
  - _Requirements: NFR 全部, 2.3_
  - _Prompt: Role: QA 工程师 | Task: 建 test target 并实现 design.md 列出的用例 | Restrictions: 不起 NSApplication；钥匙串用例 isAvailable 前置 skip；网络用例全 mock | Success: swift test 全绿_

- [ ] 14. 构建回归 + 手动验收 + README 更新
  - 进度：README 已更新 ✅；干净重建 0 警告 0 错误 ✅；swift test 25/25 全绿 ✅；冒烟启动通过（进程存活、热键注册、日志正常）✅。**剩余：design.md「End-to-End Testing」6 条手动验收清单待用户在 GUI 中执行**
  - File: README.md (modify)
  - `swift build && swift test` 通过；执行 design.md「End-to-End Testing」6 条手动验收清单并逐项记录
  - README：更新「配置」节（预设/测试连接/钥匙串与回退说明、裸可执行钥匙串询问提示）、「架构」目录树、「后续」移除已完成项；「已知限制」补充钥匙串 ad-hoc 签名询问问题
  - Purpose: 交付收口
  - _Requirements: All_
  - _Prompt: Role: 发布工程师 | Task: 全量构建回归、按清单手动验收、同步 README | Restrictions: 验收未过项回写对应任务修复后重跑 | Success: 构建测试全绿，6 条验收全过，README 与新行为一致_
