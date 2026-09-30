# ClickToKnow

macOS 全局划词释义工具：选中文字 → 按快捷键 → 就地弹出**领域感知**释义（判断技术语境，`helm` 给 K8s 包管理器而非"舵"）。

## 功能

- 全局快捷键（默认 `⌥⌘K`）抓取前台应用选中文本
- 无 AI Key 时用 macOS 系统词典兜底（`DCSCopyTextDefinition`）
- 配 Key 后用 OpenAI 兼容接口做领域感知释义（通义千问 / DeepSeek / 月之暗面 / Ollama …）
- NSPanel 悬浮窗就地展示，不抢焦点、点击外部或超时自动关闭
- 选词抓取后自动恢复用户原有剪贴板

## 运行

```bash
swift run
```

菜单栏出现放大镜图标。启动时若未授权，会引导到「系统设置 → 隐私与安全 → 辅助功能」勾选本程序（模拟 ⌘C 抓词必需）。

## 配置

### API Key（环境变量注入）

密钥通过环境变量 `CLICKTOKNOW_API_KEY` 注入，避免写进代码/仓库：

```bash
export CLICKTOKNOW_API_KEY="sk-..."
```

（可写入 `~/.zshrc` 持久化；留空则用 macOS 系统词典兜底。）

### Base URL / Model

菜单栏 → 设置 填写（存于 UserDefaults、立即生效）。以 DeepSeek 为例：

| 项 | 值 |
|---|---|
| Base URL | `https://api.deepseek.com` |
| Model | `deepseek-flash` |

> 注意：打包成 `.app` 后从 Finder 双击启动，进程不继承 shell 环境变量，`CLICKTOKNOW_API_KEY` 会读不到。此时可在设置窗口手动填入 Key（写 UserDefaults），或依赖 `launchctl setenv`。

## 架构

```
Sources/ClickToKnow/
├── ClickToKnowApp.swift        入口（accessory 激活策略）
├── App/                        AppDelegate / 菜单栏 / 设置窗口
├── Selection/                  全局快捷键 + ⌘C 抓词 + 剪贴板快照恢复
├── Interpretation/             Provider 协议 + 系统词典 + OpenAI 兼容实现
├── Config/                     UserDefaults 配置
└── UI/                         NSPanel 悬浮窗 + Markdown 渲染
```

## 已知限制

- 当前为纯 SPM 可执行文件。**辅助功能权限按进程路径记录，`swift run` 的裸可执行文件授权可能难以持久**，每次可能需重新授权。彻底解决需打成 `.app` bundle（含 `Info.plist`、签名），见下节。
- 取词当前走「模拟 ⌘C」兜底路径；后续可加 Accessibility 直读为主路径（不碰剪贴板、更快）。

## 后续（阶段 2）

- `.app` bundle 打包 + 代码签名 + 公证（需 Xcode / `Info.plist`、`LSUIElement`）
- AX 直读选中文本为主路径（`kAXSelectedTextAttribute`）
- 双击 / 拖选自动触发
- 生词本与历史记录