# ClickToKnow 当前项目评审

评审日期：2026-11-24。基线：`5582217`。依据为当前源代码、测试、README、历史评审与 CI / 发布脚本。执行 `swift test`：111 个 XCTest 用例全部通过；构建出现 AppDelegate 闭包捕获警告。本次未操作真实前台应用、辅助功能授权、剪贴板或线上 API，因此交互与时序风险需用下述场景实机验收。

## 总体判断

项目已经具备较完整的工具闭环：全局快捷键 → AX 直读 / 复制兜底 → 多协议 LLM / 本地词典 → 流式结果 → 缓存与历史记录 → 打包发布。无需重复建设旧评审中已经完成的 AX、缓存、历史、暂停、自启、CI、日志和双架构打包。

当前最值得投入的是密钥隔离、缓存正确性和请求生命周期，其次是取词响应速度与结果消费体验。P0 表示应优先处理的密钥边界问题，P1 表示日常使用正确性与可靠性，P2 表示体验或维护改进；不是线上故障统计。

## 可确认的实现问题与交互风险

### 1. P0：新增配置测试会借用当前配置的密钥

- 位置：`Sources/ClickToKnow/UI/Settings/LLMProfileEditorSheet.swift:391`。
- 新增配置时 `existing == nil`，密钥输入为空便调用 `effectiveAPIKey(for: activeProfile)`，将当前供应商密钥用于表单中新填写的地址；「测试连接」和「拉取模型」都经过该逻辑。
- 影响：配置 A 有密钥，新增配置 B 不填密钥，点击测试或拉模型，A 的密钥可能被发往 B；测试成功后保存 B 却不会复制该密钥，测试与实际查询行为也不一致。
- 建议：新增配置只允许表单显式输入的密钥或明确适用的环境配置；编辑配置仅使用其自身密钥。端点跨主机变更时提示重新确认密钥。
- 验收：保存 A 后新建 B，留空密钥请求 B，断言不携带 A 的 Authorization / API Key。

### 2. P0：遗留与明文回退密钥未绑定到具体配置

- 位置：`Sources/ClickToKnow/Config/AppConfig.swift:125`、`:167`、`:280`、`:333`。
- profile 密钥缺失时，当前生效配置回退到通用钥匙串 account 或单一 `UserDefaults.apiKey`。明文回退值没有 owner profile ID；切换生效配置后，这个全局值仍能被新配置读取，启动迁移还可能将其迁到新的生效项。
- 影响：钥匙串不可用或旧配置迁移失败等条件下，A 的密钥可能跟随切换被用于 B。与第 1 项触发路径不同。
- 建议：回退数据按 profile ID 隔离；遗留密钥只能归属迁移时确定的配置。写入失败时提供可见选择，避免自动产生新的全局明文状态。
- 验收：注入可失败的 SecretStore，覆盖 A 保存失败 → 切 B → 查询 / 重启迁移，确认 B 不获取 A 的密钥。

### 3. P1：缓存没有包含领域判断所依赖的上下文

- 位置：`Sources/ClickToKnow/Interpretation/InterpretationCache.swift:21`；`Sources/ClickToKnow/App/AppDelegate.swift:148`。
- 键仅含协议、端点、模型和转小写词条；未包括上下文与实际来源（LLM / 系统词典）。配置变更通知也未连接到缓存清理。
- 影响：先在 Kubernetes 文章查询 helm，再在航海文章查询 helm，仍返回前一释义；同一端点与模型缺密钥时缓存词典结果，补密钥后也可能继续命中词典。`US` / `us` 等大小写有意义的词条会合并。
- 建议：构造请求快照，以实际 provider 类型、必要配置标识、保留语义的词条、上下文摘要生成键；未来加入模板和语言时纳入其版本。提供清空缓存入口。
- 验收：同词不同上下文、大小写差异、词典切到 LLM 分别不串结果。

### 4. P1：请求、失败提示与关闭状态没有统一失效机制

- 位置：`Sources/ClickToKnow/App/AppDelegate.swift:65`、`:77`、`:163`；`Sources/ClickToKnow/Interpretation/OpenAICompatProvider.swift:62`。
- 只有成功取得新文本才取消上一查询并增加 requestCounter；新一次取词失败直接展示提示，旧查询仍可覆盖它。关闭仅调用 cancel，没有递增代际；最终成功和错误展示前也没有统一校验取消状态。
- 各 provider 又将部分 `URLError` 转成普通服务错误，而 AppDelegate 仅静默处理 `CancellationError`，因此网络取消可能成为「查询失败」并重新弹出窗口（具体表现需实机验证）。
- 建议：统一 query session，任何新尝试、关闭、暂停都使旧 session 失效；所有增量、成功、失败落 UI 前验证 session 与取消状态。将 `URLError.cancelled` 统一识别为取消。查询开始时冻结配置，历史记录使用该快照的模型，而非响应结束时读取可变的 shared 配置。
- 验收：慢查询时再次触发空选择、关闭窗口、暂停、切换模型，旧响应不再更新 UI 或写入错误的模型归属。

### 5. P1：AX 虽移到后台，主线程仍同步等待

- 位置：`Sources/ClickToKnow/Selection/AXSelectionReader.swift:22`、`:36`；`Sources/ClickToKnow/Selection/SelectionMonitor.swift:124`。
- 主线程调用 semaphore.wait，最坏仍等待 400ms；外层超时不终止后台 AX IPC，反复触发慢应用可能积累未完成工作。
- 建议：异步读取 + 有界并发；设置 AX messaging timeout，并让 selection session 丢弃超时 / 目标切换后的结果。超时后开始复制兜底前，重新确认目标应用与隐私条件。
- 验收：目标应用 AX 无响应时，菜单和设置仍流畅；快速触发不会持续累积后台任务。

### 6. P1：剪贴板延迟恢复窗口仍存在连续查询竞态

- 位置：`Sources/ClickToKnow/Selection/SelectionMonitor.swift:145`、`:146`；`Sources/ClickToKnow/Selection/ClipboardManager.swift:27`。
- 恢复延迟 300ms，但 `finish()` 立即解除 isProcessing；第二次查询可以在第一次恢复前保存快照，将第一次复制的词条当成原始剪贴板。changeCount 只能减少覆盖后续写入的风险，不能证明第一次变化来自目标应用。
- 建议：将快照、复制、读取、恢复纳入同一事务；恢复或放弃恢复后才释放互斥。给操作分配 token，核对前台 PID，并对第三方剪贴板写入选择保守退出。
- 验收：强制复制兜底，两次查询间隔小于 300ms；第三方剪贴板写入、延迟复制、超时均不污染原内容或误查询第三方内容。

### 7. P1：Esc 与悬停关闭行为仍有缺口

- 位置：`Sources/ClickToKnow/UI/ResultPopover.swift:139`、`:159`、`:174`。
- Esc 只使用本地事件监视器；原应用保持焦点时，按键通常交给原应用，本地监视器无法接收其他应用事件，README 的全局 Esc 关闭承诺需修正或补实现。
- 悬停仅在 mouseEntered 时取消定时器，后续流式 show 又无条件重排定时器，没有保存 isHovering，长流式内容可能在悬停期间自动关闭。
- 建议：补合适的跨应用 Esc 监听路径，明确是否仅观察或需要消费事件；保存悬停状态，将更新内容与安装监视器 / 排定关闭分开。
- 验收：Safari / VS Code 保持焦点按 Esc；鼠标持续悬停并接收长流式内容，分别验证关闭与暂停倒计时。

### 8. P1：模型列表拉取缺少防过期结果保护

- 位置：`Sources/ClickToKnow/UI/Settings/LLMProfileEditorSheet.swift:383`、`:423`。
- 连接测试有 testGeneration，但 fetchModels 没有同等机制；修改 URL / 协议 / 密钥只清空列表，旧任务返回后仍写入 fetchedModels，并可能将当前 model 改成旧端点的第一个模型。
- 建议：独立 fetchGeneration / task；端点变更和关闭编辑器时取消，完成前检查输入快照。
- 验收：端点 A 慢返回，过程中切换到 B，A 不覆盖 B 的列表与模型。

### 9. P1：错误正文透传不符合完整脱敏预期

- 位置：`Sources/ClickToKnow/Interpretation/LLMProviderSupport.swift:33`；`Sources/ClickToKnow/App/AppDelegate.swift:185`。
- 服务端错误体前 240 字节被直接拼入 UI，并提交给日志 API；第三方代理可能在错误中回显输入或鉴权信息。字节截断也可能切断 UTF-8 字符。
- 建议：优先解析结构化 error.code / type / message，清理请求密钥、敏感字段和控制字符；日志仅保留状态、错误类别和请求标识。用户按需查看经过清洗的详情。
- 验收：模拟错误体回显密钥、选中文本、HTML、非 UTF-8 内容，提示与诊断均不包含敏感原文。

### 10. P1：卸载脚本没有跟上多配置与历史功能

- 位置：`Scripts/uninstall.sh:89`；`Sources/ClickToKnow/Status/HistoryStore.swift:47`。
- 脚本按 service 调一次 delete-generic-password，没有枚举 / 验证多个 profile account 已全部清除；也没有清理 `~/Library/Application Support/ClickToKnow/history.json`。
- 建议：明确保留数据与彻底卸载两种语义；删除配置前保存 account 列表，逐项清除并验证；彻底卸载覆盖历史目录，自启状态也纳入检查。
- 验收：创建多个 API 密钥和历史，dry-run 列出全部目标；在隔离账号实测彻底卸载无残留。本次未运行卸载。

## 性能与工程可优化点

1. **流式渲染合并更新**：每个 delta 都全量 Markdown 解析、排版测高、窗口定位、重装监视器。拆分首次 show 与 updateContent，按帧或短时间窗合并增量；优先验证长内容滚动位置和主线程耗时。当前短释义规模下不必先引入复杂 diff 引擎。
2. **历史异步写入与恢复**：HistoryStore 在 MainActor 每次操作完整编码并同步落盘；文件损坏静默返回空数组，后续写入会覆盖原数据。改为串行后台持久化、合并写入、损坏文件备份与可见错误。500 条规模可继续用 JSON，暂不必为数据库迁移付出成本。
3. **统一结果渲染规则**：弹窗 MarkdownRenderer 仅处理粗体与列表，历史 MarkdownText 是另一套实现。统一语义解析与样式能力，优先覆盖行内代码、标题、链接、代码块，明确表格支持边界；不要假设原生 Markdown 初始化即可完整实现全部块级排版。
4. **测试补到用户链路**：优先补密钥隔离、缓存上下文、取消与过期响应、剪贴板事务、模型列表竞态。抽取 SecretStore / SelectionReader / Pasteboard / QueryCoordinator 接口，降低真实系统依赖。UI 与辅助功能路径补一组人工验收清单。
5. **发布质量门禁**：普通 CI 已有 build、test 和打包；tag 发布工作流本身直接打包发布，没有执行 swift test。让发布依赖同一提交的测试结果或直接测试；再补最低支持 macOS 13 与 Intel 实机 / runner 验证。Release 重跑先删全部旧附件再上传存在中断窗口，宜先验证新产物、精确替换目标附件。
6. **资源与配置管理**：每次查询新建 provider 与 URLSession，可按不可变配置复用客户端并管理 session 生命周期；先用 Instruments 检查，再决定重构幅度。清理 AppDelegate 闭包捕获警告，逐步启用 Swift 严格并发检查。
7. **诊断更可定位**：已有 os.Logger 与脱敏状态导出；可增加最近一次实际取词路径、AX / 网络耗时、首 token 耗时、缓存命中与最近失败类别。默认不记录词条、上下文、完整端点查询参数或密钥。

## 可完善功能与推荐顺序

- **近期：结果操作栏**。复制释义、收藏、发音、钉住与重试；已有文本选择和历史复制，但就地弹窗仍缺直接操作。钉住时显式关闭自动消失，并提供关闭按钮。
- **近期：隐私设置页**。黑名单图形化编辑、仅本地模式、上下文发送开关、历史记录开关、保留时长和一键清理。当前黑名单只可用 defaults 命令追加，查询成功默认落盘。
- **近期：释义模板与语言**。技术文档 / 通用阅读 / 翻译等预设，自定义模板、输出语言、长度、超时、输出 token 上限。输入过长时给出可见截断或确认，避免整篇内容误发及异常费用。
- **中期：补齐多协议流式**。Anthropic、Responses、Gemini 均未实现对应流式；OpenAI 兼容路径增加非流式开关或明确的降级策略，改善不支持 SSE 的代理兼容性。
- **中期：真正的生词本**。收藏、标签、去重与查询次数、来源应用、复习状态、Anki 导出质量提升和数据导入。现有历史窗口已经有搜索、来源筛选、删除、CSV / Anki 导出，无需重写。
- **中期：更新入口与稳定分发**。先加「检查更新 / 打开 Releases」，再根据正式签名、公证与 appcast 托管条件考虑 Sparkle。旧评审所说“没有 Release 渠道”已经过时：当前有 tag 发布工作流。
- **后续：触发与常驻偏好**。双击 / 拖选自动触发、防抖、应用级开关、纯菜单栏模式；先保证现有快捷键链路稳定，再扩展自动抓取，避免误触和隐私边界变复杂。

## 建议推进批次

1. **修正确性**：两类密钥隔离 → 缓存键 → query session / 取消 → 模型列表防过期 → 卸载完整性。
2. **稳住交互**：AX 异步化 → 剪贴板事务 → Esc 与悬停状态 → 流式更新节流。同步补相应场景测试。
3. **补高频体验**：结果操作栏 → 隐私设置 → 提示词与语言 → 全协议流式。
4. **产品化**：收藏复习 → 更新与签名 → 自动触发。DMG 视觉装饰、O(1) LRU 或立即改 SQLite 的收益低于以上任务。

本次仅新增评审文档与配套 Canvas，未修改业务代码。测试通过代表现有用例通过，不表示上述未覆盖路径已通过验证。
