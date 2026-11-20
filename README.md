# ClickToKnow

macOS 全局划词释义工具：选中文字 → 按快捷键 → 就地弹出**领域感知**释义（判断技术语境，`helm` 给 K8s 包管理器而非"舵"）。

## 常用命令

| 目的 | 命令 | 产物 / 说明 |
|---|---|---|
| 开发运行 | `swift run` | 见下文「运行」 |
| 单元测试 | `swift test` | 见下文「测试」 |
| **打包分发** | `./Scripts/package.sh` | `dist/ClickToKnow.app` + `dist/ClickToKnow-<版本>.dmg` / `.zip`，详见下文「打包与分发」 |
| 卸载清理 | `./Scripts/uninstall.sh`（`--dry-run` 预演 / `--all` 连 `.env` 一起删） | 移除 .app、配置 plist 与钥匙串密钥，详见下文「卸载」 |

## 功能

- 全局快捷键（默认 `⌥⌘K`，**可自定义**）抓取前台应用选中文本
- **设置与状态中心**（三 Tab）：辅助功能权限实时状态、快捷键绑定与注册状态、释义来源、API Key 来源与掩码一屏可见
- 无 AI Key 时用 macOS 系统词典兜底（`DCSCopyTextDefinition`）；Ollama 等**免密钥本地服务**填好 Base URL 与 Model 即可直接使用
- 配 Key 后调用 LLM 做领域感知释义（OpenAI 兼容协议：通义千问 / DeepSeek / 月之暗面 / Ollama …；Anthropic 原生 Messages API），内置供应商预设与**连接测试**
- API Key 优先存**钥匙串**（不可用时自动回退本地存储并在状态页标注）
- NSPanel 悬浮窗就地展示：不抢焦点、跟随系统亮暗外观、点击外部 / 超时 / `Esc` 关闭，关闭时自动取消在途请求
- **取词失败可见反馈**：未授权 / 安全输入态（密码框）/ 黑名单应用 / 空选择 / 超时分别给出可操作提示，不再静默无反应
- **AX 直读为主路径**：不碰剪贴板、对禁复制应用有效，弹窗贴选区（而非鼠标）展示，选区前后文随查询发送（LLM 领域判断更准）；未实现 AX 的应用自动回退模拟 ⌘C
- **SSE 流式输出**（OpenAI 兼容协议）：弹窗边收边渲染，长释义不再有数秒白屏
- **进程内查询缓存**：同一词条（含供应商 + 模型指纹）重复查询零延迟零费用
- **历史记录（生词本）**：查询自动落盘（上限 500 条），菜单栏「历史记录…」浏览，支持导出 CSV / Anki TSV
- **应用黑名单**：密码 / 密钥管理类应用（1Password、钥匙串访问等）内置不抓取，`defaults write ClickToKnow blacklistedBundleIDs -array <bundleID>` 可追加
- 菜单栏**暂停取词**开关（投屏 / 演示 / 输密码场景）与**开机自启**开关（SMAppService，打包为 .app 后生效）
- 分级日志（os.Logger，`log show --predicate 'subsystem == "ClickToKnow"'`）与**诊断信息导出**（状态页，脱敏）
- 选词抓取后自动恢复用户原有剪贴板（⌘C 兜底路径）；安全输入态（密码框聚焦）主动跳过抓取

## 运行

```bash
swift run
```

> 构建依赖 Xcode 的 SwiftUI 宏插件。若 `xcode-select` 指向 CommandLineTools，会报
> `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`；
> 先 `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 再运行即可
> （`Scripts/package.sh` 已自动切换）。

启动即打开「设置与状态中心」主窗口（状态总览 / 大模型 / 快捷键三个 Tab），Dock 与菜单栏（放大镜图标）同时存在；关闭窗口后点 Dock 图标或菜单栏「设置…」可重新唤起。启动时若未授权，会引导到「系统设置 → 隐私与安全 → 辅助功能」勾选本程序（模拟 ⌘C 抓词必需）；授权结果在「状态总览」页实时可见。

## 测试

```bash
swift test
```

覆盖键码翻译、密钥掩码、预设反查、快捷键持久化与连接测试分类（网络经 URLProtocol mock，不发真实请求）。

## 打包与分发

一条命令生成可直接安装的 `.app` 与 **DMG / zip 双格式分发件**（输出到 `dist/`）：

```bash
./Scripts/package.sh          # → dist/ClickToKnow.app
                              #   dist/ClickToKnow-0.2.1.dmg（拖入 Applications 安装布局）
                              #   dist/ClickToKnow-0.2.1.zip
```

脚本完成：release 构建（默认 arm64 + x86_64 双架构 lipo 合并，`ARCHS=arm64` 可只出单架构）→ bundle 组装（`Info.plist`、程序化生成的图标）→ 代码签名 → `ditto` 压缩 zip → `hdiutil` 生成 DMG（内含 Applications 快捷方式，打开即可拖拽安装）。`VERSION` / `BUNDLE_ID` / `SIGN_IDENTITY` / `NOTARIZE` / `ARCHS` 等均可用环境变量覆盖（见脚本头部注释）。

### 两种分发形态

| 形态 | 命令 | 用户体验 |
|---|---|---|
| Ad-hoc 签名（默认，无需账号） | `./Scripts/package.sh` | 首次打开需手动放行一次（见下方安装说明） |
| Developer ID + 公证（需 Apple 开发者账号） | `SIGN_IDENTITY="Developer ID Application: 姓名 (TEAMID)" NOTARIZE=1 ./Scripts/package.sh` | 双击直接安装，无任何提示 |

公证前需一次性存储凭据：`xcrun notarytool store-credentials notarytool --apple-id you@example.com --team-id TEAMID`。

### 用户安装说明（ad-hoc 签名版）

1. 打开 `ClickToKnow-0.2.1.dmg`，把 `ClickToKnow.app` 拖入「Applications」（zip 版则解压后拖入）
2. 首次打开会提示「无法验证开发者」：**系统设置 → 隐私与安全性 → 点「仍要打开」**（旧版 macOS 可右键 App → 打开；或终端 `xattr -dr com.apple.quarantine /Applications/ClickToKnow.app`）
3. 首次划词按引导到 **系统设置 → 隐私与安全 → 辅助功能** 勾选 ClickToKnow（`.app` 签名后授权稳定，只需一次）
4. 升级替换 `.app` 后若为 ad-hoc 重新签名，辅助功能授权可能需重新勾选；Developer ID 签名则完全不需要

### 卸载

直接把 `.app` 拖入废纸篓会**留下残留**：配置 plist、钥匙串里的 API Key、辅助功能授权条目都不会随之删除。完整卸载方式二选一：

**一键脚本**（仓库内）：

```bash
./Scripts/uninstall.sh          # 退出进程 → 删 .app → 清配置 → 删钥匙串密钥
./Scripts/uninstall.sh --all    # 连同 ~/.clicktoknow（手动创建的 .env）一起删
./Scripts/uninstall.sh --dry-run # 预演，只打印不改动
```

**手动卸载**（仅有 DMG/zip 的用户，终端逐条执行）：

```bash
osascript -e 'tell application "ClickToKnow" to quit'   # 或先手动退出
rm -rf /Applications/ClickToKnow.app
defaults delete ClickToKnow            # 配置 suite（快捷键/Base URL/Model）
defaults delete com.clicktoknow.app    # 系统自动写入的窗口状态等
security delete-generic-password -s ClickToKnow   # 钥匙串里的 API Key
rm -rf ~/.clicktoknow                  # 若按 README 创建过 .env
```

最后到 **系统设置 → 隐私与安全 → 辅助功能** 移除残留的 ClickToKnow 条目（TCC 数据库受 SIP 保护，无法脚本化删除；不删也无害，重装时会重新匹配）。

## 配置

菜单栏 → 「设置…」打开设置与状态中心：

| Tab | 内容 |
|---|---|
| 状态总览 | 辅助功能权限（1s 实时刷新 + 直达系统设置）、快捷键绑定与注册状态、当前释义来源、API Key 掩码与来源、版本 / 可执行路径 |
| 大模型 | 供应商预设一键填充，API 协议（OpenAI 兼容 / Anthropic）+ Base URL / API Key / Model 编辑，连接测试（成功返回耗时，失败分类展示原因），保存后立即生效 |
| 快捷键 | 点击录制新热键（需至少含 ⌘ / ⌥ / ⌃ 之一），冲突自动回滚原绑定，支持恢复默认 `⌥⌘K` |

### API Key

密钥读取优先级：**环境变量 → 钥匙串 → 遗留 UserDefaults 明文**（启动时自动迁移至钥匙串，幂等）。

#### `.env` 文件注入（优先级最高）

`.env` 已被 git 忽略，不会提交：

```bash
cp .env.example .env
# 编辑 .env，填入 CLICKTOKNOW_API_KEY=sk-...
```

> 注意：打包成 `.app` 从 Finder 双击启动时，进程**不继承 shell 环境变量**，且工作目录不是项目根，会读不到项目根 `.env`。此时可改用 `~/.clicktoknow/.env`（Home 目录下，打包后仍可定位），或在设置窗口「大模型」页填 Key（写入钥匙串）。

#### 设置窗口填写

保存的密钥写入钥匙串（service=`ClickToKnow`）；钥匙串不可用时（裸可执行 ad-hoc 签名重编译后可能被拒）自动回退 UserDefaults，状态页会标注「来自本地存储（已回退）」。UI 与日志中密钥一律以掩码展示（如 `sk-a••••3456`）。

### Base URL / Model

「大模型」页选择供应商预设（DeepSeek / 通义千问 / 月之暗面 / 智谱清言 / OpenAI / Anthropic / Ollama 本地）一键填充，也可选「自定义」手填。API 协议随预设自动切换：Anthropic 走原生 Messages API（`x-api-key` 鉴权），其余走 OpenAI 兼容协议。保存前建议点「测试连接」验证：以表单当前值发一次最小对话请求，成功显示耗时，失败按网络不可达 / 401 密钥无效 / 404 模型或路径不存在等分类提示。以 DeepSeek 为例：

| 项 | 值 |
|---|---|
| Base URL | `https://api.deepseek.com` |
| Model | `deepseek-chat` |

## 架构

```
Sources/ClickToKnow/
├── ClickToKnowApp.swift        入口（regular 激活策略，启动即展示主窗口）
├── App/                        AppDelegate / 菜单栏（动态状态 + 暂停/自启/历史入口）/ 设置窗口壳 / 系统设置直达
├── Selection/                  全局快捷键（配置化 + 热重注册）+ AX 直读（主）+ ⌘C 抓词（兜底）+ 剪贴板快照恢复 + 键码翻译
├── Interpretation/             Provider 协议（含流式可选能力）+ 系统词典 + OpenAI 兼容（SSE 流式 + ping）+ Anthropic + 连接测试门面 + 查询缓存
├── Config/                     UserDefaults 配置（含应用黑名单）/ 钥匙串密钥存储 / 供应商预设 / 分级日志（os.Logger）
├── Status/                     运行时状态聚合（AppStatusModel）+ 历史记录持久化（HistoryStore）
└── UI/                         NSPanel 悬浮窗 + Markdown 渲染 + SwiftUI 设置页（三 Tab）+ 历史记录窗口
Packaging/                      Info.plist 模板 + 应用图标（Scripts/make_icon.swift 程序化生成）
Scripts/                        package.sh 一键打包（默认 universal binary）/ uninstall.sh 卸载清理 / make_icon.swift 图标生成
Tests/ClickToKnowTests/         纯逻辑单测 + URLProtocol mock 集成测试（含 SSE 流式与历史导出用例）
```

## 已知限制

- 开发模式（`swift run`）下**辅助功能权限按进程路径记录，裸可执行文件授权难以持久**，钥匙串读取也可能因 ad-hoc 签名变化反复询问；这两点在 `./Scripts/package.sh` 打包的 `.app` 形态下均已解决（仅 ad-hoc 重签升级后授权可能需重勾一次）。
- 默认打包产物为 universal binary（arm64 + x86_64）；只需单架构可 `ARCHS=arm64 ./Scripts/package.sh`（构建更快、产物更小）。
- Anthropic 协议暂为非流式整包（OpenAI 兼容协议已支持 SSE 流式）。

## 后续（阶段 3）

- 双击 / 拖选自动触发
- 提示词模板自定义（内置「技术文档 / 通用阅读」场景预设）
- Anthropic 协议 SSE 流式、Sparkle 自动更新（需 appcast 托管与签名基础设施）
- 历史记录收藏标记与复习、菜单栏黑名单 UI 编辑
- DMG 自定义背景与图标布局