# ClickToKnow 功能完善度评审

> 依据：33 个 Swift 源文件（约 2,540 行）全量通读 + 同类工具（Bob / Easydict / PopClip）对标 · 2026-11-20
> 共 17 项发现：1 个确认缺陷、4 项 P0（核心链路）、9 项 P1（体验与产品化）、3 项 P2（工程化）

## ⚠️ 确认缺陷：Ollama「密钥可选」预设实际不可用

`ProviderPresets.swift:45` 把 Ollama 标为 `apiKeyOptional: true`，但 `AppConfig.swift:86` 的 `hasLLMConfig` 强制要求 apiKey 非空，`ProviderFactory.swift:7` 以此为唯一闸门——**选 Ollama 且留空密钥的用户会被静默回落到系统词典，本地模型从未被调用**。

修复：`hasLLMConfig` 按当前预设的 `apiKeyOptional` 判定，或 baseURL + model 齐备即启用 LLM 路径。

---

## P0 · 核心链路缺陷

| 缺口 | 现状与代码位置 | 建议 |
|---|---|---|
| **取词只有「模拟 ⌘C」一条路** | `SelectionMonitor.swift:92` 发送合成 ⌘C 事件；禁复制场景（密码管理器、受保护 PDF、部分网页）直接失效；恢复快照靠 changeCount 比对，第三方剪贴板工具（Maccy 等）中途写入会误丢用户剪贴板；20ms 轮询 × 500ms 超时对 Electron / 大文档偏紧 | README 阶段 3 已列 AX 直读，建议提前为主路径：`kAXSelectedTextAttribute` 不碰剪贴板、更快，⌘C 降级为兜底 |
| **弹窗定位跟鼠标不跟选区** | `AppDelegate.swift:58` 用 `NSEvent.mouseLocation` 定位；键盘选词（⌘A、Shift+方向键）时鼠标可能在屏幕另一端，弹窗出现在无关位置 | AX 直读后用 `kAXBoundsForRangeParameterizedAttribute` 取选中文本矩形贴边弹出；取不到再回退鼠标位置 |
| **取词失败完全静默** | `SelectionMonitor.swift:83` 空选择 / 超时 / 未授权三种失败只写 NSLog，用户按了快捷键毫无反馈，无法区分「没权限」还是「没选中」 | 失败态也要弹轻量提示；权限缺失时在提示里放「去授权」直达按钮（SystemSettingsOpener 已有现成能力） |
| **隐私保护缺位** | 无 SecureInput 检测（密码框聚焦时仍可取词）、无应用黑名单（1Password / 银行类）、选中文本无差别发往远程 LLM；`LLMProviderSupport.swift:27` 错误时把 240 字符服务端响应原文带上 UI，可能含敏感回显 | 查询前检查 `IsSecureEventInputEnabled()`；加应用黑名单与「仅本地词典」开关；错误片段做白名单字段提取而非整段透传 |

## P1 · 释义能力与结果消费

| 缺口 | 现状与代码位置 | 建议 |
|---|---|---|
| **Markdown 渲染撑不住自家提示词** | `MarkdownRenderer.swift` 只支持 `**粗体**` 和 `- ` 列表；提示词却让模型输出含链接、术语表的 5 个小节，行内代码 / 链接 / 表格会原样露符号 | macOS 12+ 自带 `NSAttributedString(markdown:)`，一行替换即可覆盖标题 / 链接 / 代码 / 表格 |
| **弹窗硬编码浅色、交互为零** | `ResultPopover.swift:57` 固定浅底深字，深色模式刺眼；无钉住（pin）、无 Esc 关闭、无「复制释义」按钮、无发音（`NSSpeechSynthesizer` 几行即可朗读选中词） | 颜色换 `labelColor / controlBackgroundColor` 自适应；加 pin 与 Esc；音标既然已展示，发音按钮是低成本高感知功能 |
| **无查询缓存** | 同一个词每次重查都打一次远程 API，重复阅读技术文档时延迟与费用双倍付出 | 内存 LRU（几百条足够）+ 可选持久化；设置页加「清空缓存」与缓存命中率状态 |
| **无流式输出、请求不可取消** | `OpenAICompatProvider.swift:28` 写死 `stream:false`，长释义数秒白屏；popover 关闭后请求继续烧 token（requestCounter 只丢结果不断连）；max_tokens=512 / temperature=0.2 全部写死 | SSE 流式渲染（Loading 25s 的体感会彻底改观）；popover 关闭时 cancel URLSessionTask；高级设置开放 max_tokens / temperature |
| **「领域感知」名不副实** | 卖点是判断技术语境，但只把单词本身发给模型（`OpenAICompatProvider.swift:31`），选区前后文完全没用上，领域判断靠模型盲猜；提示词与输出语言写死，看论文 / 小说场景不适配 | AX 直读时顺带取段落级上下文一并发送；提示词开放为可编辑模板或至少提供「技术文档 / 通用阅读」预设 |

## P1 · 产品化缺口

| 缺口 | 现状 | 建议 |
|---|---|---|
| **无开机自启** | 常驻工具类应用重启后即失效，用户要手动重开——这是留存杀手级缺口 | macOS 13+ 原生 `SMAppService.loginItem`，几行代码 + 设置页开关 |
| **无更新机制** | 打包脚本已支持公证，但用户装完即孤岛：无版本检查、无自动更新、无 Homebrew cask | 接入 Sparkle（业界标准）；至少先在状态页加「检查更新」指向 Releases |
| **无全局暂停 / 模式切换** | 投屏演示、录屏、输密码时想临时禁用只能退出整个应用；regular 策略下 Dock 图标常驻，偏好「纯菜单栏」的用户无选择 | 菜单栏加「暂停取词」开关（注销热键即可）；设置页加 Dock 图标显隐（activationPolicy 切换） |
| **无历史记录 / 生词本** | README 阶段 3 已列；划词工具查完即焚，无法回顾与积累 | 查询历史（SQLite / JSON 均可）+ 收藏 + 导出 Anki / CSV；与查询缓存共用存储层 |

## P2 · 工程化

| 缺口 | 现状 | 建议 |
|---|---|---|
| **测试盲区在核心链路** | 6 个测试文件全是纯逻辑（掩码 / 键码 / 预设 / 连接测试）；SelectionMonitor、ClipboardManager、ResultPopover、密钥迁移这些最容易回归的地方零覆盖 | ClipboardManager / 快照恢复逻辑可纯逻辑化后补测；密钥迁移用注入 UserDefaults + 内存钥匙串替身测试 |
| **无 CI、日志体系原始** | 仓库无 GitHub Actions 等工作流，`package.sh` 未进 CI 回归；日志只有 NSLog，无级别、无聚合、无导出，远程排障靠口述 | CI 至少跑 `swift test` + 打包脚本冒烟；日志换 `os.Logger` 分级，设置页加「导出诊断信息」（脱敏后打包配置与日志） |
| **分发形态打磨** | README 已列：默认 arm64，无 universal binary；DMG 无自定义背景与图标布局 | `--arch arm64 --arch x86_64` 双编 + lipo 合并；DMG 背景图与拖拽布局脚本化 |

---

## 建议落地顺序

| 批次 | 内容 | 理由 |
|---|---|---|
| **第一批（小时级）** | Ollama 判定缺陷修复、取词失败可见反馈、Esc 关闭弹窗、深色模式自适应 | 改动小、风险低、用户感知最直接 |
| **第二批（核心重构）** | AX 直读为主路径（连带解决禁复制失效、选区定位、上下文传递三个 P0/P1） | 一项改动撬动最大体验收益，README 已列应提前 |
| **第三批（成本与体验）** | 查询缓存、SSE 流式、请求可取消、隐私保护（SecureInput / 黑名单） | 降低每次查询的延迟与费用，补上合规短板 |
| **第四批（产品化）** | 开机自启、暂停开关、生词本与导出、Sparkle 自动更新、CI 与诊断日志 | 从「能用的脚本」到「可分发的产品」 |

## 与 README「阶段 3」的关系

README 已列 AX 直读、双击 / 拖选自动触发、生词本、universal binary 四项，本评审不复述。以上为计划外补充：其中 **Ollama 缺陷、取词失败静默、深色模式、隐私保护、开机自启、自动更新、查询缓存**七项在现有规划中完全缺失，建议补入路线图。

---

## 治理记录（2026-11-20 第一批已完成）

本批落地 8 项，`swift build` + `swift test`（47 例）全绿：

| 评审项 | 状态 | 实现 |
|---|---|---|
| Ollama 免密钥预设不可用（确认缺陷） | ✅ 已修复 | `AppConfig.isLLMReady`：空密钥时按预设 `apiKeyOptional` 判定；设置页密钥提示随预设区分；新增 `AppConfigLLMReadyTests`（6 例） |
| 取词失败完全静默 | ✅ 已修复 | `SelectionFailure` 四类失败（未授权/安全输入/空选择/超时）经弹窗给出可操作提示；未授权前置检查避免干等 500ms |
| 弹窗深色模式刺眼 | ✅ 已修复 | 底色/边框/文字全部改用动态颜色（`windowBackgroundColor` / `separatorColor` / `labelColor`） |
| 弹窗无 Esc 关闭 | ✅ 已修复 | 本地键事件监视器拦截 Esc 并消费，避免前景应用二次响应 |
| 请求不可取消（关窗烧 token） | ✅ 已修复 | `currentRequest` 持有任务句柄；关窗 / 新查询发起即取消（`CancellationError` 静默丢弃） |
| 无查询缓存 | ✅ 已修复 | `InterpretationCache` 进程内 LRU（容量 200，键含供应商+模型指纹）；新增 `InterpretationCacheTests`（8 例） |
| 隐私：安全输入态仍可取词 | ✅ 已修复 | 抓取前检查 `IsSecureEventInputEnabled()`，命中即跳过并提示 |
| 无暂停开关 / 无开机自启 | ✅ 已修复 | 菜单栏新增「暂停取词」（注销热键，状态页显示「已暂停」而非误报「注册失败」）与「开机自启」（SMAppService） |

未动项（需更大改动，仍建议按原批次推进）：AX 直读主路径、SSE 流式、选区上下文传递、应用黑名单、生词本、Sparkle、CI/日志体系、universal binary。

---

## 治理记录（2026-11-20 第二批已完成）

本批落地 8 项，`swift build` + `swift test`（64 例，新增 17 例）全绿；`package.sh` 实测产出 universal binary（`lipo -archs` = x86_64 arm64）+ DMG 校验通过：

| 评审项 | 状态 | 实现 |
|---|---|---|
| 取词只有模拟 ⌘C 一条路（P0） | ✅ 已修复 | 新增 `AXSelectionReader`：AX 直读为主路径（后台线程 + 0.4s IPC 超时），⌘C 降级兜底；禁复制应用（受保护 PDF 等）从此可用 |
| 弹窗定位跟鼠标不跟选区（P0） | ✅ 已修复 | AX 路径经 `kAXBoundsForRange` 取选区矩形（坐标系翻转已处理），弹窗贴选区展示；取不到回退鼠标位置 |
| 「领域感知」名不副实（P1） | ✅ 已修复 | AX 顺带取选区 ±200 字符上下文，经 `LLMProviderSupport.userPrompt` 随查询发送（含防御：区间文本不含选中词则弃用） |
| 无流式输出（P1） | ✅ 已修复（OpenAI 兼容协议） | `StreamingInterpretationProvider` 可选协议 + SSE 逐行解析，弹窗边收边渲染；Anthropic 维持整包（SSE 事件结构不同，列入阶段 3） |
| 隐私：无应用黑名单（P0） | ✅ 已修复 | 内置密码/密钥管理类应用黑名单 + `defaults write ClickToKnow blacklistedBundleIDs` 用户追加；命中即跳过并提示 |
| 无历史记录 / 生词本（P1） | ✅ 已修复 | `HistoryStore`（JSON 持久化，上限 500 条）+ 历史记录窗口（分栏浏览）+ 导出 CSV / Anki TSV（转义有单测） |
| 无 CI、日志体系原始（P2） | ✅ 已修复 | GitHub Actions CI（build + test + 打包冒烟）；NSLog 全量替换为 `os.Logger` 分级日志；状态页新增「导出诊断信息」（脱敏状态汇总） |
| 无 universal binary（P2） | ✅ 已修复 | `package.sh` 默认双架构 lipo 合并（`ARCHS` 环境变量可覆盖）；顺带修复非 UTF-8 locale 下变量名粘连全角字符的兼容问题 |

明确不做及理由：**Sparkle 自动更新**——需要 appcast 托管与稳定的正式签名身份，仓库尚无远端 Release 渠道；当前可在状态页核对版本号后手动下载 DMG。列入阶段 3。
