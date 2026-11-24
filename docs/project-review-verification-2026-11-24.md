# ClickToKnow 评审核查与批次 1 修复记录

对应文档：`docs/project-review-2026-11-24.md`。基线提交 `5582217`，本次工作在分支 `fix/correctness-batch-1`。

本文档记录两轮工作：批次 1（修正确性）与批次 2（稳住交互）+ 工程优化项。批次 2 与工程项为后续追加。

核查方式：4 个只读核查代理并行取证（只读代码与 git 历史，未改文件、未跑构建），逐条以「代码逐字摘录 + 调用链 + 触发序列 + 现有测试覆盖」判定结论；随后由主代理统一实施批次 1 修复。基线与本轮验证均在 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`、`swift build --disable-sandbox` 下执行（仅装 CommandLineTools 时 SwiftUI 宏插件缺失，构建会失败）。

## 一、逐条核查结论

| # | 评审结论 | 核查判定 | 关键证据 |
|---|---|---|---|
| 1 | P0 新增配置借用生效密钥 | **部分成立** | `LLMProfileEditorSheet.swift:391` `effectiveFormKey()` 确实以 `existing ?? activeProfile` 兜底；但影响面不止「新增配置」：`LLMConnectionTester.swift:35` 的 `apiKey.isEmpty ? AppConfig.shared.apiKey : apiKey` 让**编辑任意无已存密钥的非生效配置**点「测试」也会借用生效密钥。另有一处偏差：「测试成功后保存 B 却不复制密钥」属实，但环境变量分支（`:126`）对所有配置生效是设计如此（UI 已禁用输入框），不应计为缺陷 |
| 2 | P0 遗留/明文回退密钥无 owner | **成立** | `AppConfig.swift:125/167/280/333` 行号全部准确。补强证据：`deleteProfile` 只删 `profile-<uuid>` 条目，遗留默认 account/明文不清；默认 account 的迁移只在 `apiProfiles.isEmpty` 分支执行，**列表非空时遗留钥匙串密钥既不迁移也不失效**，任何新生效项都能读到 |
| 3 | P1 缓存缺上下文与来源 | **成立**（需限定） | 键仅四段且 term 转小写（`InterpretationCache.swift:21`）；`context` 在作用域内但不入键（`AppDelegate.swift:147`）；`cache.removeAll()` 生产代码**零调用**；`llmConfigChangedNotification` 唯一消费方是 `AppStatusModel.refresh`，未接线到缓存。「缺密钥→词典」串用成立，但前提是该配置已存端点+模型、密钥为空且非密钥可选预设 |
| 4 | P1 请求/失败/关闭无统一失效 | **成立** | 最硬的一条是评审未列出的：`SystemDictionaryProvider.swift:9` 用 `Task.detached` + `.value`，detached 不继承取消、`.value` 也不抛 `CancellationError`，**词典路径取消后必然正常返回**，于是「关窗后释义重新弹出」可稳定复现。另：4 个 Provider 均把 `URLError` 归一为服务错误，`networkHint` 无 `.cancelled` 分支 |
| 5 | P1 AX 后台化但主线程仍同步等待 | **成立** | `AXSelectionReader.swift:36` `semaphore.wait(timeout: 0.4)` 在主线程；后台 block 无取消机制；`AXUIElementSetMessagingTimeout` 全仓 0 命中。行号偏差 1 行（调用点在 `SelectionMonitor.swift:125`，`:124` 是注释） |
| 6 | P1 剪贴板延迟恢复竞态 | **成立**（窗口更窄） | `restoreSnapshot` 只「排程」恢复（`ClipboardManager.swift:30-37`），`SelectionMonitor.swift:146` 却立即 `finish()` 释放互斥。精确化：竞态窗口是 `finish()` 之后的 300ms 尾巴，且需第二次查询的 AX 快速失败才落得进来 |
| 7 | P1 Esc 与悬停缺口 | **成立**（两条子结论均成立） | `ResultPopover.swift:139-148` 注释自我矛盾：「键事件仍发往原焦点应用」与「本地监视器能拦截」互斥；类中无 `isHovering`，`show()` 末尾无条件 `scheduleAutoClose()`（`:123-126`），流式 delta 每次都整份 `show()`（`AppDelegate.swift:159/170`），悬停暂停会被覆盖 |
| 8 | P1 模型列表无防过期 | **成立** | `fetchModels`（`:423`）无代际；`invalidateEndpointDerivations`（`:383`）只清列表不取消任务；旧响应回填后还会把 Model 改成旧端点的第一个模型 |
| 9 | P1 错误正文透传 | **部分成立** | 透传与「提交给日志」属实，但两处需修正：`String(decoding:)` 对截断的半个 UTF-8 序列替换为 U+FFFD，**不会产生非法字符串或崩溃**；`os.Logger` 对动态字符串默认 `<private>`，`log show` 默认看不到正文。另有一处评审未列的第二条透传路径：`ModelCatalogFetcher.swift:47` → `LLMConnectionTester.swift:53` → `LLMProfileEditorSheet.swift:443` 展示在设置页 |
| 10 | P1 卸载脚本不完整 | **成立，且比评审所列更严重** | 除漏多 profile 钥匙串与 `history.json` 外：`run()` 的 `[dry-run]` 输出在 `:89-93` 被调用点 `>/dev/null 2>&1` 吞掉（预演对第 3/4 步完全无输出），而 `:90` 的 `find-generic-password` 前置检查不受 dry-run 保护（预演也真实访问钥匙串）；`SMAppService` 自启项与 `BUNDLE_ID` 可覆盖情形均未处理 |

核查结论：10 条中 7 条完全成立、3 条部分成立（差异均已在上表注明），**没有一条被证伪**。评审的「需实机验收」保留项（问题 5 的 AX 时序、问题 6 的竞态表现、问题 7 的 Esc 前置条件）本次未实机操作，仍属待验证。

## 二、批次 1 已修复

分支 `fix/correctness-batch-1`。修复范围＝评审「建议推进批次 1：修正确性」。

### 1. 密钥隔离（问题 1 + 2）

- 新增 `Config/SecretStoring.swift`：`SecretStoring` 协议 + 钥匙串实现 `KeychainSecrets`；`AppConfig` 改为注入 `any SecretStoring`（默认仍走钥匙串），使「钥匙串写入失败」这条不可控路径可被单测覆盖。
- `AppConfig` 新增遗留密钥归属：`legacyAPIKeyOwnerProfileID`。遗留默认 account 与明文只在 `owner == profile.id` 时可见；无 owner 的历史数据一律不认，由迁移补归属。
- 迁移语义改为「只归给迁移时确定的配置」：owner 已记录 → 只迁给 owner（owner 已删除则丢弃遗留值）；owner 未记录 → 归当前生效配置，且只此一次；首个配置创建时（`upsertProfile`）收编无主遗留值。
- `setAPIKey` 回退明文时必须写入 owner；`deleteProfile` / `clearAPIKey` 清理归属它的遗留存储。
- `effectiveFormKey()`：新增配置不再借用任何已存密钥；编辑配置只用自身密钥，且**端点主机变更后不再自动沿用**（`LLMProviderSupport.endpointHost`），`keyHint` 给出「请重新输入密钥」提示。
- `LLMConnectionTester`：删除 `apiKey.isEmpty ? AppConfig.shared.apiKey : apiKey` 隐式回退（仅保留环境变量这一全局来源）。
- 语义简化：因为回退明文已按配置隔离，非生效配置也能安全保存，`LLMProfileSaveResult.keySaveFailed` 这一「完全没能保存」状态不再可达，已移除，UI 只保留「钥匙串不可用，密钥已回退本地存储（按配置隔离）」。

### 2. 缓存键（问题 3）

- `InterpretationCache.Key` 由字符串改为结构体：`source`（词典/LLM）、`baseURL`、`model`、`term`（**保留大小写**）、`contextDigest`、`promptFingerprint`（提示词版本 + 协议 + 归属配置 id）。
- 上下文摘要：空白归一 + 转小写 + 截断 160 字符。取舍写在代码注释里：不做全文压缩，优先保证「同词不同上下文绝不串」。
- `AppDelegate` 订阅 `llmConfigChangedNotification` → `cache.removeAll()`，把此前零调用的 `removeAll()` 接上。
- `Context` 相关：`InterpretationCache.promptVersion` 常量作为提示词改版时的整体失效开关。

已知代价：上下文参与键后，同一篇文章里选区上下文略有差异即不会命中。命中率下降是可接受的正确性优先取舍，后续若要提高命中率需引入领域摘要而非降低键精度。

### 3. 请求生命周期（问题 4）

- 新增 `Interpretation/QuerySnapshot.swift`：
  - `QuerySnapshot`：查询开始时冻结的配置（profileID / 协议 / 端点 / 模型 / 清洗后密钥 / 是否走 LLM），派生出 `source` 与 `historyModel`。
  - `QuerySession`：代际管理（`begin()` / `invalidate()` / `isCurrent()`）。
- `AppDelegate`：`requestCounter` 换成 `querySession`；新增 `invalidateCurrentQuery()`，在**新查询、弹窗关闭、暂停取词、展示取词失败提示**四处统一调用；增量、成功、失败三路落 UI 前一律校验代际。
- 缓存写入与历史归属改用快照，响应回来不再读可变的 `AppConfig.shared`。
- `LLMProviderSupport.networkError`：把 `URLError(.cancelled)` 统一还原为 `CancellationError`，4 个 Provider 全部切换。
- `SystemDictionaryProvider`：`Task.detached` 取回结果后补 `Task.checkCancellation()`，修掉「关窗后词典释义重新弹出」。
- 顺带清掉了基线里的 `AppDelegate.swift:168` 闭包捕获警告（`[weak self]` 提前到 `Task`）。

### 4. 模型列表防过期（问题 8）

- `LLMProfileEditorSheet` 新增 `fetchGeneration`：`fetchModels` 换代并在写入前校验；请求参数取发起时刻快照；`invalidateEndpointDerivations` 换代并解除 loading，避免旧任务让按钮永久禁用。

### 5. 卸载脚本（问题 10）

- `Scripts/uninstall.sh` 重写（119 → 394 行）：8 步固定顺序；从 `defaults export` 解析 `apiProfiles` 逐条删除 `profile-<uuid>` 并复验，再清遗留 `apiKey`；区分「条目不存在（退出码 44）」与「授权被拒」；默认保留 `history.json` 与 `~/.clicktoknow`，`--purge` 才删（`--all` 为别名）；`--dry-run` 打印每一步且零副作用；钥匙串处理严格早于删除 `.app`；结尾输出「自动清理范围 + 仍需手动处理」清单。
- `README.md` 卸载小节同步（含手动卸载需逐条 `-a profile-<uuid>` 的修正）。

## 三、验证

```
swift build --disable-sandbox   # 0 error / 0 warning（仅 SwiftPM 自身 user-level cache 噪声）
swift test --disable-sandbox    # 136 tests, 0 failures
```

基线为 111 个用例，本轮新增 25 个，集中在评审要求的验收面：

- `Tests/ClickToKnowTests/SecretIsolationTests.swift`（10 个）：A 保存失败 → 切 B 后 B 拿不到 A 的密钥；重启迁移不把归属 A 的明文迁到生效的 B；钥匙串恢复后只迁入归属配置；`deleteProfile` / `clearAPIKey` 清理归属遗留；无主遗留值只归首个配置；新增配置不借用生效密钥；测试连接不再隐式回退；`endpointHost` 归一化。
- `Tests/ClickToKnowTests/QueryLifecycleTests.swift`（10 个）：代际失效与幂等、id 单调；快照的 `usesLLM` / `source` / `historyModel` / 密钥清洗；来源参与缓存键；`URLError(.cancelled)` → `CancellationError`。
- `Tests/ClickToKnowTests/InterpretationCacheTests.swift`（重写，13 个）：大小写保留、上下文隔离、`nil` 与空上下文等价、来源隔离（词典 ↔ LLM）、配置指纹（含 profileID）、LRU、`removeAll`。
- `TestHelpers.InMemorySecretStore`：替换真实钥匙串。原 `AppConfigProfilesTests` 等用例会真实读写开发者本机钥匙串的默认 account，迁移用例甚至可能把真密钥挪走，现已全部注入内存实现。

`Scripts/uninstall.sh` 额外验证：`bash -n` 通过；子任务用假 `PATH`（`defaults`/`security`/`pgrep`/`osascript`/`launchctl`/`rm` 桩）跑了 10 组用例共 86 条断言，覆盖 dry-run 零副作用、真实调用序列与顺序、`--purge`/`--all`、无配置与坏配置降级、授权被拒逐条报错。本机真实 `--dry-run` 也确认：能从实际配置正确解析出 `profile-<uuid>` 并只打印、不触碰钥匙串。

## 四、批次 2 已修复（稳住交互）

### 6. AX 异步化（问题 5）

- `AXSelectionReader.read()` 改为 `async` + `withCheckedContinuation`：工作线程与超时定时器竞争同一个 continuation，由 `ResumeGate` 保证只 resume 一次；**主线程不再 `semaphore.wait` 阻塞**。
- 新增 `AXUIElementSetMessagingTimeout(appElement/element, 0.2)`：此前系统默认 6s，远大于 400ms 预算，超时返回后后台线程仍挂在 IPC 上，快速连按会累积未完成调用。
- `SelectionMonitor` 取词全程持有互斥（一次只允许一个 AX 读取），并用代际号 `readToken` 丢弃过期结果；暂停时递增代际。
- 兜底前 `revalidate(target:)` 复核：目标 pid 未变、仍非安全输入、仍非黑名单；目标已切换则新增 `SelectionFailure.targetChanged` 并给出可操作提示，绝不复制别处的内容。
- 依赖通过 `Environment` / `SelectionReading` / `PasteboardAccess` / `DelayScheduling` 注入，测试无需辅助功能授权。

### 7. 剪贴板事务（问题 6）

- 新增 `PasteboardAccess` 协议；`restoreSnapshot` 改为带 `completion`：**互斥一直持有到快照真正恢复完成**。此前 `finish()` 在排程恢复后立即放锁，第二次查询能赶在 300ms 恢复窗口内保存快照，把本次复制的词条当成「用户原始剪贴板」。
- 事务带 `token`：被暂停/新查询取代时，仍恢复快照但拒绝交付结果。
- 未采用「changeCount 跳变即判定第三方写入」的启发式：不少应用一次 ⌘C 会 `clearContents` + `writeObjects`（计数跳 2），按跳变拒绝会误杀正常取词；恢复前仍以 `changeCount == readCount` 作为不覆盖第三方内容的条件。

### 8. Esc 与悬停（问题 7）

- 新增 `AutoCloseScheduler` 状态机：`isHovering` 由它持有，悬停期间 `restart(duration:)` 直接拒绝排定——这是「流式内容每帧重排定时器、把悬停冻结覆盖掉」的根因修复。
- `ResultPopover.show()` 拆为「首次展示（装监视器 + 排倒计时）」与 `updateContent`（只重排内容，锚点沿用首次展示位置）。
- Esc 补 `addGlobalMonitorForEvents`（原应用保持焦点时唯一可达路径），本地监视器继续负责可消费场景。README「已知限制」明确：全局监视器无法消费事件，原应用仍会收到该 Esc；不使用 CGEventTap 是有意取舍（否则会吞掉所有应用的 Esc）。

### 9. 错误正文脱敏（问题 9）

- `serverError` 改为「状态码 + 白名单字段（`error.type` / `error.code` / `error.message` 等）」；非 JSON 走纯文本清洗。
- 清洗链：去控制字符与 U+FFFD → 剥 HTML 标签 → 凭证打码（`sk-`/`Bearer`/≥32 字符无分隔串）→ 压空白 → **按 Character 截断**（旧实现按字节 `prefix(240)` 会切出半个 UTF-8 字符）。
- 新增 `InterpretationError.logCategory`：日志只记 `server(status=401)` 这类类别，不再写入服务端正文。设置页「拉取模型 / 测试连接」的同一路径自动受益。

### 10. 流式渲染合并（性能项 1）

- 新增 `StreamingCoalescer`：50ms 窗口合并增量，只交付最新文本，流式结束 `flush()` 保证末帧落地；时间源与调度器可注入。
- 增量改走 `updateContent`，不再每帧重装监视器/重排倒计时。100 个 delta 的突发场景单测断言渲染次数 < 10。

## 五、工程优化项已修复

- **历史异步写入与损坏恢复**（工程项 2）：新增 `HistoryFileWriter`（串行后台队列 + 合并写，只落盘最新快照）；损坏文件不再静默返回空数组，而是备份为 `history.corrupt-<时间戳>.json` 并在历史窗口顶部给出橙色告警；`applicationWillTerminate` 前 `flush()`。
- **统一结果渲染解析**（工程项 3）：新增 `MarkdownDocument` 共享块级/行内解析，弹窗 `MarkdownRenderer` 与历史详情 `MarkdownText` 共用；弹窗侧补齐标题、有序列表、引用、代码块、分隔线、行内代码与链接。表格明确不支持（按段落原样显示，不静默丢内容）。
- **人工验收清单**（工程项 4）：新增 `docs/acceptance-checklist.md`，覆盖 A 取词主路径、B 剪贴板事务、C 弹窗交互、D 日志脱敏、E 密钥隔离、F 缓存、G 历史、H 卸载、I 发布门禁，并列出待补验证项。
- **发布门禁**（工程项 5）：`release.yml` 新增 `verify` job（`swift build` + `swift test`），`build-release` 依赖它——tag 推送此前完全不跑测试；新增产物完整性校验（存在、非空、`hdiutil verify`）；重跑发布改为「`--clobber` 覆盖同名产物 → 清理过期附件」，消除「先删全部附件再上传」的空窗。
- **闭包捕获警告**（工程项 6 的一部分）：基线 `AppDelegate.swift:168` 的警告已清除，构建零警告。

## 六、未修复（明确留待后续批次）

- **批次 3 高频体验**（结果操作栏、隐私设置页、释义模板与语言、全协议流式）与**批次 4 产品化**（收藏复习、更新入口、自动触发触发方式）未动：这些会改变 UI/交互设计，需要产品决策，未擅自实现。
- **工程项 6 的其余部分**（provider 与 URLSession 按不可变配置复用）：评审明确要求「先用 Instruments 检查，再决定重构幅度」，本轮未做性能剖析，不做无依据重构。
- **工程项 7 诊断增强**（最近取词路径 / AX 与网络耗时 / 首 token 耗时 / 缓存命中 / 最近失败类别）：本轮已让日志不再含正文（`logCategory`），但结构化耗时指标未加，留待后续。
- **缓存命中率下降**：上下文入键后的已知代价，需要领域摘要才能补回，本轮以正确性优先。
- **仍需实机验收**：见 `docs/acceptance-checklist.md`；其中 macOS 13 与 Intel 实机验证、真实钥匙串授权被拒后的删除复验、辅助功能 TCC 与 `SMAppService` 残留清理未覆盖。

本次核查未修改任何评审原文；业务代码改动仅限上述批次 1 范围。