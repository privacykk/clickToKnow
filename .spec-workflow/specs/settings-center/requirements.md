# Requirements Document

## Introduction

将现有单一「设置窗口」（仅 Base URL / API Key / Model 三个输入框）升级为**设置与状态中心**：一个分 Tab 的前端页面，集中展示应用运行配置信息（辅助功能权限状态、快捷键绑定、大模型就绪状态、密钥来源、运行时信息），并提供大模型配置增强（预设供应商、连接测试、钥匙串存储）与快捷键自定义能力。

目的与价值：
- 当前辅助功能权限只在启动时弹一次系统引导，用户授权后无处确认是否生效；`swift run` 裸可执行文件权限易失效，问题难以自查。
- 快捷键 `⌥⌘K` 硬编码在 `SelectionMonitor` 中，注册成功与否只写 NSLog，用户不可见、不可改。
- 大模型配置填错（Base URL / 模型名 / 密钥失效）时，用户要到实际划词失败才发现；需要「保存前可验证」的连接测试。
- API Key 目前明文存 UserDefaults，需要迁移到钥匙串。

## Alignment with Product Vision

README「后续（阶段 2）」已将密钥钥匙串化列为方向；本特性是其落地，并补齐配置可见性（权限/快捷键/LLM 状态一屏可见），降低工具类 App 的排障成本，为后续 `.app` 打包分发做准备。

## Requirements

### Requirement 1：状态总览页

**User Story:** 作为 ClickToKnow 用户，我想在一个页面里看到权限、快捷键、大模型等运行配置的实际状态，以便出问题时能自查自修。

#### Acceptance Criteria

1. WHEN 用户打开设置窗口并停留在「状态总览」Tab THEN 系统 SHALL 展示以下条目，且每秒自动刷新：
   - 辅助功能权限：已授权（绿）/ 未授权（红），数据源 `AXIsProcessTrusted()`；
   - 快捷键：当前绑定的可读形式（如 `⌥⌘K`）+ 注册状态（已注册 / 注册失败）；
   - 释义来源：`大模型（<model>）` 或 `系统词典（未配置 LLM）`；
   - API Key：掩码形式（如 `sk-1••••xyz`）+ 生效来源（环境变量 / .env / 钥匙串 / 设置窗口遗留 / 未配置）；
   - 运行时：版本号、可执行文件绝对路径（辅助排查裸可执行文件权限问题）。
2. IF 辅助功能权限为「未授权」THEN 系统 SHALL 在状态行旁提供「打开系统设置」按钮，点击直达「隐私与安全 → 辅助功能」面板。
3. WHEN 用户在系统设置中勾选授权后回到状态页（不重启应用）THEN 系统 SHALL 在 1 秒内将权限状态刷新为「已授权」。
4. WHEN 用户离开「状态总览」Tab 或关闭设置窗口 THEN 系统 SHALL 停止轮询定时器（避免常驻开销）。

### Requirement 2：大模型配置页

**User Story:** 作为用户，我想通过预设一键填充供应商配置、保存前测试连通性，以便快速接入 DeepSeek / 通义千问等服务并当场确认配置正确。

#### Acceptance Criteria

1. WHEN 用户在「大模型」Tab 选择预设供应商（DeepSeek / 通义千问 / 月之暗面 / 智谱 / OpenAI / Ollama 本地 / 自定义）THEN 系统 SHALL 自动填充对应 Base URL，并提供该供应商的推荐模型列表供选择或手输。
2. WHEN 用户编辑 Base URL / API Key / Model 并点击「保存」THEN 系统 SHALL 校验 Base URL 以 `http://` 或 `https://` 开头，写入配置并立即生效（下一次划词即用新配置），无需重启。
3. WHEN 用户点击「测试连接」THEN 系统 SHALL 以**表单当前值**（而非已保存值）向 `<baseURL>/chat/completions` 发起一次最小请求（`max_tokens=1`），并在 15 秒内展示结果：成功（含耗时 ms）或失败（区分：网络不可达 / 超时 / 401 密钥无效 / 404 模型不存在或路径错误 / 其他 HTTP 状态码及响应片段）。
4. IF API Key 已由环境变量或 .env 提供 THEN 系统 SHALL 展示「密钥已由环境提供（掩码）」且表单密钥输入框留空；此时保存空密钥 SHALL NOT 清除环境变量密钥的生效状态。
5. WHEN 用户保存非空 API Key THEN 系统 SHALL 将其写入钥匙串（service=`ClickToKnow`），不再写入 UserDefaults 明文。
6. WHEN 应用启动读取密钥 THEN 系统 SHALL 按优先级解析：环境变量 → 钥匙串 → UserDefaults（遗留），并支持一键迁移：IF UserDefaults 存在遗留明文密钥且钥匙串可写 THEN 系统 SHALL 写入钥匙串并删除 UserDefaults 中的明文。
7. WHEN 钥匙串读写失败（如裸可执行文件重编译后签名变化被拒）THEN 系统 SHALL 回退到 UserDefaults 存储并在 UI 标注「钥匙串不可用，已回退本地存储」，不得导致应用崩溃或密钥丢失。
8. WHEN 用户点击「清除已存密钥」THEN 系统 SHALL 同时清除钥匙串与 UserDefaults 中的密钥（环境变量来源的密钥不受影响，仅提示其仍生效）。

### Requirement 3：快捷键绑定与自定义

**User Story:** 作为用户，我想看到当前快捷键及其注册状态，并能改成自己习惯的组合键，以便避开与其他软件的冲突。

#### Acceptance Criteria

1. WHEN 用户打开「快捷键」Tab THEN 系统 SHALL 展示当前绑定（可读形式）、注册状态，并提供录制控件与「恢复默认（⌥⌘K）」按钮。
2. WHEN 用户点击录制控件并按下组合键 THEN 系统 SHALL 捕获 keyCode 与修饰键，要求至少包含 ⌘ / ⌥ / ⌃ 之一；不满足时提示并保持原值。Esc SHALL 取消录制。
3. WHEN 新绑定被确认 THEN 系统 SHALL 立即注销旧热键并按新值调用 `RegisterEventHotKey` 热重注册，成功后持久化到 UserDefaults（`hotKeyKeyCode` / `hotKeyModifiers`）。
4. IF 热重注册失败（组合键被系统或其他应用占用）THEN 系统 SHALL 恢复原绑定继续生效，并在 UI 提示「注册失败，可能被占用」，不持久化失败值。
5. WHEN 应用下次启动 THEN 系统 SHALL 使用持久化的绑定注册热键；无持久化值时使用默认 `⌥⌘K`。
6. WHEN 绑定变化后用户展开菜单栏菜单 THEN 系统 SHALL 显示最新绑定（如「快捷键：⌃⌥J（先选中文字）」）。

### Requirement 4：菜单与入口整合

**User Story:** 作为用户，我想从菜单栏直接感知应用健康状况，以便不打开窗口也能发现问题。

#### Acceptance Criteria

1. WHEN 用户点开菜单栏菜单 THEN 系统 SHALL 实时刷新并显示：快捷键条目（当前绑定）、辅助功能权限条目（「辅助功能权限：已授权 ✓」或「辅助功能权限：未授权 — 去授权」，后者点击直达系统设置）。
2. WHEN 用户点击「设置…」THEN 系统 SHALL 打开设置与状态中心（默认停留在「状态总览」Tab），窗口可复用（重复点击不新开实例）。

## Non-Functional Requirements

### Code Architecture and Modularity
- **Single Responsibility Principle**：新增文件各司其职——`KeychainSecretStore`（密钥存取）、`CarbonKeyTranslator`（键码翻译）、`ProviderPresets`（预设数据）、`LLMConnectionTester`（连通测试）、`AppStatusModel`（状态聚合）、SwiftUI 视图仅做展示与交互。
- **Modular Design**：SwiftUI 视图通过 `AppStatusModel`（ObservableObject）与运行时解耦；配置变更经 NotificationCenter 广播，`SelectionMonitor` 订阅后热重注册，不产生 UI↔Selection 直接依赖。
- **Dependency Management**：零新增 SPM 依赖（SwiftUI / Security 均为系统框架）。
- **Clear Interfaces**：`InterpretationProvider` 协议不变；`OpenAICompatProvider` 仅新增 `ping()` 方法。

### Performance
- 权限状态轮询仅在「状态总览」Tab 可见时运行（1s 间隔），Tab 切走或窗口关闭即停止。
- 连接测试超时上限 15s，不阻塞主线程（async/await）。
- 热键重注册为同步轻量操作（<1ms），不影响划词主流程。

### Security
- API Key 不明文出现在：UI（一律掩码）、NSLog（禁止输出完整密钥）、UserDefaults（新写入走钥匙串）。
- 掩码规则：保留前 4 后 4 字符，中间以 `••••` 替代；长度 ≤8 的密钥全掩码。
- 连接测试请求仅携带表单值，测试日志不记录 Authorization 头。

### Reliability
- 钥匙串不可用时自动回退 UserDefaults，功能降级但可用（见 R2.7）。
- 热键注册失败自动回滚原绑定（见 R3.4）。
- 配置读取全部提供默认值，UserDefaults 损坏/缺键不导致崩溃。

### Usability
- 三个 Tab 命名：「状态总览」「大模型」「快捷键」；窗口约 560×520，不可调整大小。
- 所有破坏性/耗时操作（测试连接、清除密钥、迁移）有进行中状态与结果反馈。
- 状态刷新无需用户手动点击；同时提供「刷新」按钮兜底。
