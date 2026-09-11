# ZCode Control 下一轮 9 小时彻底迭代计划

## 0. 交付目标

这是一份可以交给另一位编码 AI 直接执行的 9 小时作战计划。总时长严格为 540 分钟，不把“写完代码”当成完成；每个阶段都必须有可运行的验收门槛和提交点。

最终要得到：

- 一个原生统一会话 shell：打开设备后直接进入正常会话，draft 只是空会话状态。
- 一条真正可靠的 native Relay → Agent RPC → workspace/session → conversation stream 数据链。
- 创建、发送、实时回复、思考展开、技能/工具展示、权限操作、停止都不依赖 WebView。
- 模型、真实思考级别、上下文 used/max、统计、技能、插件、MCP 和 Agent 能力在原生页面自动读取。
- 模型/思考切换使用真实协议和回执，不靠硬编码或“打开远控页同步”。
- 消除重复消息、迟到回执覆盖、旧连接覆盖新连接和“已连接但不可发送”。
- 设置、通知、截图、安全和无障碍行为清晰、可回归。
- 自动化测试、协议 fixtures、故障注入、静态安全扫描和 Android release 验证完整。
- 桌面上的交接 ZIP 可让另一位 AI 在 D 盘解压后立即开工，并包含 WorkBuddy 参考材料的隔离副本。

本计划不授权把本机凭据、远控 URL、sid/hash、keystore、key.properties、ZCode app.asar 或 WorkBuddy 专有文件提交到 GitHub。WorkBuddy 二进制只能放在本地交接 ZIP 的 reference 目录，且必须有参考用途声明。

## 1. 基线和约束

### 1.1 当前源码

仓库：

~~~text
<PROJECT_ROOT>
~~~

当前基线提交：8c79d3d。

当前已知结构：

- lib/ui/native_device_view.dart 直接打开 NewConversationPage。
- lib/ui/new_conversation_page.dart 独立负责创建会话。
- lib/ui/conversation_page.dart 负责历史、composer、模型/思考/上下文和停止。
- lib/state/conversation.dart 负责正文、配置加载、发送、停止。
- lib/state/relay_source.dart 负责 bridge、service RPC 和若干工作台入口。
- lib/state/conversation_config.dart 负责宽松的模型/思考/上下文解析。
- lib/state/panel_state.dart 负责 payload 扫描型面板数据。

这些文件是现状证据，不是必须维持的最终架构。下一轮允许重构，但必须保持现有已通过的协议/通知/生物识别测试不回退。

### 1.2 证据

当前版本真机反馈在 docs/FEEDBACK-AUDIT-20260910.md 中编号 S01–S11。重点问题：

- 显示“原生通道已连接”后仍无法创建/发送。
- 模型 chip 有值但模型菜单为空。
- 配置变更被桌面端拒绝。
- 消息重复。
- 停止仍需要确认。
- 统计、模型、插件、MCP 依赖打开远控页。
- 首页是独立新对话欢迎页。

### 1.3 本轮停止项

用户已要求停止当前测试，因此执行 AI 不得自动连接 ADB、扫描设备、打开远控链接或使用真机凭据。真机验收只写成可复现脚本和手工清单，等用户明确重新授权后执行。

### 1.4 时钟纪律

总预算 9 小时 = 540 分钟。每个阶段结束必须写一条简短进度记录，说明：

- 已完成的验收条目。
- 未完成的条目和原因。
- 新增/修改文件。
- 测试命令和结果。
- 是否允许进入下一阶段。

若协议字段不确定，不能编造。先查本机 ZCode 安装包：

~~~text
<ZCODE_INSTALL>\resources\app.asar
~~~

可以解包或搜索方法名，但不得复制 app.asar、远控 token 或完整 URL 到 Git/ZIP。

## 2. 九小时总排程

| 时间 | 分钟 | 阶段 | 关键输出 | 门槛 |
| --- | ---: | --- | --- | --- |
| 00:00–00:30 | 30 | 基线、证据、协议勘探 | issue ledger、调用地图、sanitized fixtures 目录 | 现有测试可运行；不丢用户改动 |
| 00:30–01:25 | 55 | Native bootstrap 与 readiness | 单设备 coordinator、epoch、能力清单 | 不再出现“绿点但不可发送” |
| 01:25–02:15 | 50 | 统一 ConversationShell | draft/已有会话同一页面 | 首页不再 push 到独立新对话页 |
| 02:15–03:25 | 70 | Runtime config 和真实 RPC | model/thought/context 的来源、解析、回执 | 模型/思考/上下文不再假数据 |
| 03:25–04:10 | 45 | Composer 与停止状态机 | one-slot action、去确认、去重 reducer | 发送/停止互斥且不重复 |
| 04:10–05:00 | 50 | Workbench、Agent、Settings 自动加载 | repository + cache + pending intent | 不打开 WebView 也能取数据 |
| 05:00–06:05 | 65 | 原生 UI/IA/可访问性 | 统一 tokens、抽屉、空态、错误态 | 视觉结构达到规格，不能破坏状态语义 |
| 06:05–07:00 | 55 | 生命周期、后台、通知、截图和安全 | 安静模式/持续模式、FLAG_SECURE 修正 | 不常驻骚扰通知、不泄漏凭据 |
| 07:00–08:15 | 75 | 自动化、自测试和故障注入 | unit/widget/golden/integration/contract | 关键 P0 测试全部通过 |
| 08:15–09:00 | 45 | 全量验证、APK、交接包 | release APK、checksums、Desktop ZIP | 可交接、无密钥/凭据、结果可复核 |

总计：30 + 55 + 50 + 70 + 45 + 50 + 65 + 55 + 75 + 45 = 540 分钟。

## 3. 阶段 00:00–00:30：基线、证据和协议勘探

### 00:00–00:08：保护现场

执行：

~~~powershell
git status --short
git log -5 --oneline
flutter analyze
flutter test
~~~

要求：

- 不使用 git reset --hard、git checkout -- 或清理用户文件。
- 记录基线测试数量和失败项。
- 如果现有测试失败，标为 BASELINE-FAIL，不要把它们误归到新改动。

### 00:08–00:18：代码调用地图

用 rg 建立下列表格：

| 能力 | UI 入口 | 当前 state/notifier | 当前 RPC | 目标 repository |
| --- | --- | --- | --- | --- |
| Relay | AppShell/NativeDeviceView | relaySourceProvider | bridge.start/handshake | ConnectionRepository |
| 工作区/会话列表 | Drawer/Tasks | sessionIndexProvider | workspace/task bootstrap | WorkspaceRepository |
| 正文 | ConversationPage | conversationProvider | conversationRowsRangeV4/subscribe | ConversationRepository |
| 模型/思考/上下文 | Composer | ConversationRuntimeConfig | readSession/getTaskTokenUsage/switch | RuntimeConfigRepository |
| 统计/模型目录 | Panels/usage | panelDataProvider/页面 FutureBuilder | usage-stats、相关 agent method | WorkbenchRepository |
| 技能/插件/MCP | settings panels | skills/plugins/mcp providers | list/get overview | WorkbenchRepository |
| 安全/通知 | Settings | biometric/notification providers | native preferences | SettingsRepository |

找出所有下列行为并登记：

- addPostFrameCallback 后直接调用 service。
- 读取 isLive 但不等待 conversationReady。
- UI 自行追加 row。
- 硬编码 thought levels。
- showDialog 停止确认。
- onOpenWebView 或“打开远控页”占位文案。
- FLAG_SECURE/截图限制。
- 前台服务常驻 notification。

### 00:18–00:30：本机协议勘探和 fixture 规则

检查 app.asar 中：

- Relay handshake 的 service/method 列表。
- session read/current config/model catalog。
- thought option/capability 字段。
- context usage 字段。
- create/send/stop receipt。
- usage stats、skills、plugins、MCP 和设置读取方法。

只把“字段名、类型、脱敏后的最小 payload”写入：

~~~text
test/fixtures/native/verified/
docs/PROTOCOL-DELTA-20260911.md
~~~

删除 sid、hash、token、机器名、绝对用户路径和消息正文。找不到权威方法时记录 NOT-VERIFIED，并让 UI 显示 unsupported/notReturned；不允许凭猜测实现写操作。

阶段提交点：

~~~text
chore: freeze native iteration baseline and protocol evidence
~~~

进入下一阶段条件：

- 当前测试结果已记录。
- P0 问题有编号。
- 至少有一个 sanitized fixture 或明确的待验证清单。

## 4. 阶段 00:30–01:25：Native bootstrap 与 readiness

### 00:30–00:42：建立状态模型

新增或重构：

~~~text
lib/native/bootstrap/native_bootstrap_state.dart
lib/native/bootstrap/native_bootstrap_coordinator.dart
lib/native/bootstrap/native_capability_manifest.dart
lib/native/bootstrap/native_request_receipt.dart
~~~

状态至少包含：

- transportPhase。
- agentPhase。
- workspacePhase。
- conversationPhase。
- connectionEpoch。
- lastSuccessAt。
- lastFailure {layer, method, code, safeMessage}。
- capabilities。
- pendingIntents。

每个布尔值都要能追溯到一个枚举状态；不要再用 fromNative/isLive/subscribed 三个布尔值推断所有 readiness。

### 00:42–00:57：单设备 owner 和 epoch

在 relaySource 或 ConnectionRepository 中实现：

1. deviceId → 单一 bridge。
2. 新连接生成 epoch。
3. 旧 bridge 的 payload、phase、failure、receipt 回调全部带 epoch。
4. 旧 epoch 结果丢弃。
5. connect 并发调用共享 Future。
6. disconnect/reconnect 清理 timer、stream、pending request。
7. session-conflict/other-device 接管时，释放旧 owner 并显示真实原因，不自动创建第二条相同凭证连接。

### 00:57–01:12：bootstrap 阶段和优先级

实现顺序：

1. Relay start。
2. Agent service handshake。
3. capability manifest。
4. workspace/task/session index。
5. 选定 workspace/session。
6. runtime config。
7. 当前页面所需 workbench。

预热请求使用单设备队列/并发上限。会话必要请求优先，统计和大列表可后置。

### 01:12–01:25：把 readiness 接入 UI

ConversationShell 只能在以下条件同时满足时允许发送：

~~~text
relayReady
AND agentReady
AND workspaceResolved
AND conversationReady
AND sessionReady(or draftCreateReady)
~~~

连接状态文案必须对应具体层：

- 正在连接桌面端。
- 已连接，正在初始化 Agent。
- 已连接，正在读取工作区。
- 会话已就绪。
- 会话订阅失败，可重试。
- 设备不支持 native Relay。

不能再用“原生通道已连接”覆盖所有情况。

阶段门槛：

- bootstrap 单元测试通过。
- 人工读代码确认任何旧 epoch 不能写新 state。
- S01/S02 的矛盾状态在 scripted relay fixture 中可复现并被 UI 正确区分。

提交点：

~~~text
feat: add single native bootstrap coordinator and readiness state
~~~

## 5. 阶段 01:25–02:15：统一 ConversationShell

### 01:25–01:38：抽离页面入口

目标文件：

~~~text
lib/ui/native_device_view.dart
lib/ui/new_conversation_page.dart
lib/ui/conversation_page.dart
lib/ui/session_detail_page.dart
~~~

改动：

- NativeDeviceView 直接返回 DeviceConversationShell/ConversationPage。
- sessionId 改为 nullable 或引入 DraftConversationIdentity。
- workspacePath 允许先为空，等 bootstrap 后填充。
- 删除新会话页面上的大图标、独立 welcome layout 和 pushReplacement 流程。
- NewConversationPage 改成 DraftComposer 子组件，或在本阶段末删除。

### 01:38–01:52：shell 的 draft 和 existing 模式

统一构造：

~~~dart
ConversationPage(
  deviceId: device.id,
  workspacePath: resolvedWorkspace,
  sessionId: resolvedSessionId,
  mode: ConversationMode.draftOrExisting,
)
~~~

Draft：

- 顶部仍有设备、工作区、连接状态。
- 时间线只显示轻量提示。
- composer 立即可输入；工作区未确定时保留草稿但发送禁用。
- 创建成功后更新 identity，不切换页面。

Existing：

- 拉取 rows、订阅 stream、加载 config。
- 保留当前会话滚动位置和展开状态。

### 01:52–02:05：抽屉和工作区排序骨架

把会话抽屉从“简单列表”改成 device → workspace → session 分组：

- workspacePath 规范化。
- pinned 优先。
- running/waiting approval 次之。
- updatedAt 降序。
- 未归类单独分组。
- 标题同名时加短 ID。

先建立纯函数排序/分组，后续用 session index 数据接入。

### 02:05–02:15：路由与返回行为

- 新会话不 pushReplacement。
- 点击历史会话只替换 shell identity。
- 返回键在 conversation shell 与根 tab 之间有稳定规则。
- notification tap 指向具体设备/工作区/session。
- 不为原生默认路径创建 WebView。

阶段门槛：

- 首屏 widget 测试能证明 NativeDeviceView 不实例化 NewConversationPage。
- draft → create success 仍是同一 widget route/key。
- drawer 排序测试覆盖两个工作区、未归类、置顶和运行中。

提交点：

~~~text
feat: unify draft and existing sessions in native conversation shell
~~~

## 6. 阶段 02:15–03:25：Runtime config 和真实 RPC

这是本轮最重要的 70 分钟。模型、思考和上下文不能只修 UI。

### 02:15–02:30：方法与返回形状确认

根据 00:18–00:30 的 app.asar 结果，建立：

~~~text
NativeCapabilityManifest
  runtimeConfig.read
  runtimeConfig.models
  runtimeConfig.thoughtLevels
  runtimeConfig.context
  runtimeConfig.update
  usage.read
~~~

每个方法记录：

- service。
- method。
- args schema version。
- response selector。
- read/write。
- testedAt。
- unsupported fallback。

若本机桌面版本只提供一个 session snapshot，就由一个 parser 同时抽取 current/model catalog/thought/context；如果提供多个方法，就分别读取并按 revision 合并。

### 02:30–02:48：RuntimeConfigRepository

新增：

~~~text
lib/repositories/runtime_config_repository.dart
lib/models/native_runtime_snapshot.dart
~~~

状态：

- loading。
- snapshot。
- modelCatalogState。
- thoughtOptionsState。
- contextState。
- freshness。
- revision。
- error。
- pendingWrite。

实现：

- 一个 device/workspace/session key。
- request single-flight。
- read cache → fresh request。
- 过期结果不能覆盖更新 revision。
- snapshot、usage、catalog 合并时保留各自 provenance。
- 失败不清除上一次 fresh/stale 值。

### 02:48–03:03：防御式 parser 和模型目录

保留当前 tolerant parser 的优点，但修正：

- 不把 arbitrary map 当模型。
- provider/model ID 必须同时存在。
- 支持真实目录的 list/map/provider grouped 形状。
- enabled=false 的模型显示禁用原因。
- 当前模型可以在目录缺失时单独显示，但 selector 必须说目录未返回。
- 目录最多解析安全上限，防止异常 payload 造成卡顿。
- 解析错误记录字段路径，不记录敏感值。

模型 chip 与模型 sheet必须来自同一个 repository snapshot，不能一个读 session、一个读 payload 扫描。

### 03:03–03:15：真实 thought/context

思考：

- options 来自 selected model capabilities 或 manifest。
- 当前值和选项分离。
- 不再硬编码 none/low/medium/high/xhigh 为真实选项。
- 桌面端只返回当前值时，选择器显示只读当前值。

上下文：

- 只接受明确 context fields。
- used/max/threshold 独立。
- 任何缺失显示未返回。
- 不从 usage quota、消息数量或模型名推断。

### 03:15–03:25：写回和回执

模型/思考更新流程：

1. 读取当前 snapshot/revision。
2. 验证目标值属于当前能力。
3. 发送最小 patch，带 revision/etag（如协议支持）。
4. 等待 accepted/applied/rejected。
5. 成功后重新读取权威 snapshot。
6. 失败保留旧值，显示 service/method/code 的安全文案。

单独切换模型不能强行带上一个 UI 默认 thought；如果协议要求二者一起发，必须由 manifest 明确表示。

阶段门槛：

- parser tests 覆盖 6 种真实/历史形状。
- model chip 和 sheet 共用一份 state。
- update rejected 不发生乐观永久变化。
- model/thought/context 的 fixture 中没有账号/路径/token。

提交点：

~~~text
feat: centralize verified runtime config discovery and updates
~~~

## 7. 阶段 03:25–04:10：Composer、停止和重复消息

### 03:25–03:38：ConversationReducer

新增或重构：

~~~text
lib/state/conversation_reducer.dart
lib/models/conversation_identity.dart
~~~

所有 initial/older/live/receipt/optimistic/refresh 输入只能进 reducer。

identity 优先级：

1. rowId。
2. entityId。
3. toolCallId。
4. messageId/clientOperationId。
5. session + role + timestamp bucket + normalized content hash（标低置信度）。

规则：

- 同 identity 更新，不追加。
- pending user row 收到官方 row 后替换。
- receipt 只更新状态。
- refresh 空结果不能清掉实时内容。
- 分页并入后排序去重。

### 03:38–03:50：发送状态机

状态：

~~~text
idle
→ preparing
→ pendingReceipt
→ streaming
→ completed
→ failed(retryable)
~~~

每次发送生成 clientOperationId。超时不能自动重复写入；必须先查询/等待迟到 receipt，用户再次点击重试时明确提示可能重复。

### 03:50–04:00：单一 primary action

重构 ComposerBar：

- 输入行最右侧只有一个主动作。
- 空输入显示 plus/attachment。
- 有文本/附件显示 send。
- sending 显示 spinner。
- running/waiting 显示 stop square。
- stopping 显示不可点击 spinner。
- 不再同时放 stop 和 send。
- paperclip 为 secondary attachment control。

### 04:00–04:10：停止和错误交互

- 删除 showDialog 停止确认。
- 点击立即 set stopping 并 haptic。
- 一个 epoch 内最多一个 stop request。
- 成功/失败通过状态和 snackbar 提示。
- actionError 不遮盖时间线，不把旧失败永久留在顶部。

阶段门槛：

- S05 的重复消息能被 reducer 合并。
- S06 无 dialog 测试。
- send/stop 互斥测试。
- 发送失败时文本和附件仍然存在。

提交点：

~~~text
fix: unify conversation reducer and single-slot composer actions
~~~

## 8. 阶段 04:10–05:00：Workbench、Agent 能力和 Settings 自动加载

### 04:10–04:22：WorkbenchRepository

新增：

~~~text
lib/repositories/workbench_repository.dart
lib/models/native_resource_state.dart
~~~

统一收口：

- usage stats。
- model/provider overview。
- skills。
- plugins。
- MCP。
- commands。
- subagents。
- hooks。
- memory。
- indexing。

每项都按 device/workspace key 保存 state、provenance、lastSuccessAt、error。

### 04:22–04:35：bootstrap 预热和 pending intent

Coordinator ready 后自动触发读请求。页面先打开但 relay 未 ready 时：

1. 页面读取已有 cache。
2. 注册 intent。
3. 显示 skeleton/connecting。
4. coordinator ready 后执行一次。
5. 页面销毁只取消该页面 listener，不取消 repository 请求。

同一 key 的并发 load 必须 single-flight；refresh 才能显式绕过 fresh cache。

### 04:35–04:47：改造页面空态

目标页面：

- AgentUsagePage。
- model panel。
- PluginsPage。
- McpServersPage。
- SkillsPage。
- AgentResourcePage。
- SettingsPanelPage。

删除或替换“在远控页打开一次面板后会自动同步”的文案。统一显示：

- 正在从本机读取。
- 本机返回空列表。
- 本机没有提供此能力。
- 连接失败，点击重试。
- 显示上次缓存，最后同步时间。

### 04:47–05:00：Settings 自身状态

Settings 页面进入即读取：

- native connection/diagnostics。
- notification mode。
- screenshot policy。
- biometric state。
- battery optimization。
- theme/locale。
- capability summary。

每个写开关等待回执，失败回滚，不能只改变本地 UI。

阶段门槛：

- widget tests 验证页面进入不调用 Navigator 打开 WebView。
- scripted relay fixture 能让 usage/model/plugin/MCP 从 loading 变成 data。
- 未连接状态显示 retry，不显示网页前置依赖。

提交点：

~~~text
feat: make workbench and settings data native-first and auto-loading
~~~

## 9. 阶段 05:00–06:05：UI、IA、动画和无障碍

这一小时只在状态层稳定后做。任何视觉改动不得重新引入假数据和路由分裂。

### 05:00–05:15：主题 tokens

统一：

- background/surface/field。
- textHigh/textMedium/textLow。
- accent/live/warning/danger。
- border/hairline。
- spacing 4/8/12/16/24/32。
- radius 8/12/16。
- typography title/body/label/caption。

所有页面颜色只走 theme tokens；深色、浅色、动态字体都要有测试。

### 05:15–05:30：ConversationShell 视觉层

- 顶部标题最多两行：会话标题 + 工作区/连接状态。
- draft 空态变小，composer 靠近可操作区域。
- 时间线使用轻分隔线和留白。
- 思考、工具、权限块折叠但状态明显。
- 错误用局部 banner/snackbar，不占满整个正文。
- composer 始终贴底并兼容键盘 inset。

### 05:30–05:45：drawer 和底部导航

- 汉堡菜单打开分组会话抽屉。
- 分组标题显示工作区 basename/路径摘要。
- 状态 pill 一致。
- 底部导航标签不和正文滚动冲突。
- 使用 44–48dp 触控目标。

### 05:45–05:55：loading/error/empty/stale

每个页面至少实现：

- skeleton。
- pull/manual retry。
- stale data + last sync。
- empty data。
- unsupported。
- transport error。

禁止所有空页面都采用同一个巨大居中图标。

### 05:55–06:05：无障碍快速验收

- icon 有 semantics/tooltip。
- TalkBack 读出 primary action。
- 动态字体 200% 不溢出。
- 颜色之外还有文字/图形状态。
- 键盘 Enter 发送，Esc/返回关闭 sheet。

提交点：

~~~text
style: rebuild native shell and workbench information hierarchy
~~~

## 10. 阶段 06:05–07:00：生命周期、通知、截图与安全

### 06:05–06:18：后台策略

提供两个可理解的模式：

安静模式（默认）：

- 不常驻“后台守护中”通知。
- App 进入后台停止持续 WebSocket 或按系统允许的调度重连。
- 回到前台立即 bootstrap/reconcile。
- 未读事件在前台补同步。

持续连接模式（用户主动开启）：

- 使用合规前台服务。
- notification 仅说明连接状态，不显示敏感文本。
- 用户能在设置中关闭。

不能通过隐藏前台通知绕过 Android 系统规则。

### 06:18–06:30：通知 channel

- foreground service channel：低重要性、静默。
- event channel：默认只通知栏，重要性由用户/系统控制。
- 不主动启动 Activity。
- 事件去重，解决/完成事件取消旧通知。
- 通知点击带 deviceId/sessionId，进入原生 shell。

### 06:30–06:42：截图策略

检查 Android：

- FLAG_SECURE。
- Window flags。
- biometric overlay。
- 最近任务预览。

要求普通页面可截图。敏感字段用 redaction，不用全局禁截屏。增加 Android instrumentation/配置测试，确认无意间被 overlay 设置为 secure。

### 06:42–06:54：凭据和日志

- sid/hash/token 只进 secure storage/内存。
- 日志仅允许 device alias、epoch、service、method、duration、safe code。
- 禁止打印 args/response 全量。
- error stack 可本地 debug，但发布包不包含敏感 payload。
- 交接包扫描 URL、key.properties、jks、p12、passHash 值。

### 06:54–07:00：安全门槛

跑：

~~~powershell
rg -n -i 'remote/v4\?sid=|keyPassword=|storePassword=|passHash=[A-Za-z0-9+/=]{16,}' .
rg -n 'FLAG_SECURE|setSecure|WINDOW_SECURE' android lib
~~~

第一条不得出现真实凭据；第二条必须有明确的用户选择/最近任务策略说明，不能无条件全局启用。

提交点：

~~~text
fix: make background, notification, screenshot and logging policies explicit
~~~

## 11. 阶段 07:00–08:15：自动化、自测试和故障注入

详细测试合同见 docs/AUTOMATION-SELF-TEST-PLAN.md。此处是执行顺序。

### 07:00–07:12：纯逻辑和 parser

必须有：

- native_bootstrap_state_test.dart。
- runtime_config_repository_test.dart。
- conversation_identity_test.dart。
- conversation_reducer_test.dart。
- workspace_grouping_test.dart。
- notification_policy_test.dart。

覆盖旧 epoch、空字段、未知字段、重复 receipt、无 rowId、上下文缺失、模型目录为空。

### 07:12–07:25：协议 fixture 和 fake relay

新增：

~~~text
test/fixtures/native/verified/*.json
test/fake_relay/fake_relay_server.dart
test/fake_relay/failure_script.dart
~~~

fake relay 至少能模拟：

- handshake 成功。
- handshake 延迟。
- service method not found。
- response out of order。
- duplicate stream row。
- dropped create receipt。
- stale epoch response。
- stop rejected。
- reconnect during streaming。

### 07:25–07:40：widget tests

必须验证：

- NativeDeviceView 不进入 NewConversationPage。
- draft 与 existing 共用同一 shell。
- 模型 chip/sheet 同一数据源。
- thought 选项未返回时不能出现伪造的可选项。
- context used/max 缺失的显示。
- Composer 只有一个 primary action。
- stop 无 dialog。
- 异常有 retry，不跳 WebView。
- 200% text scale 可布局。

### 07:40–07:55：golden tests

固定至少 8 张 golden：

1. draft + relay connecting。
2. draft + ready。
3. existing + history。
4. model sheet loading/data/empty。
5. thought sheet authoritative options。
6. context used/max/unknown。
7. running + stop action。
8. workbench stale/error/empty。

使用统一字体/locale/屏幕尺寸；golden 失败先判断是否是预期视觉改动，不能简单更新 golden 掩盖回归。

### 07:55–08:05：integration tests

不连真机，使用 fake relay 驱动：

1. bootstrap。
2. 打开 draft。
3. 创建会话。
4. 发送“你好”。
5. 收到 thinking/tool/assistant rows。
6. 展开思考。
7. 切换模型/思考。
8. 查看 context/usage。
9. 点击停止。
10. 模拟断线和恢复。

断言：

- 一条 user row。
- 一条对应 assistant turn。
- 没有 WebView route。
- 一次 stop request。
- old epoch 不污染新 state。

### 08:05–08:15：性能和安全扫描

预算：

- cold start 到首个 shell frame：正常 fixture 下可接受且不白屏。
- 单次 payload 最大深度/条目有限制。
- 500 条会话列表滚动无明显卡顿。
- 日志不含凭据。
- package source 不含 build/.dart_tool/keys。

阶段门槛：

- flutter analyze 0 issues。
- 新增测试全部通过。
- 全量旧测试无新增失败。

提交点：

~~~text
test: add native conversation contract fixtures and failure-injection coverage
~~~

## 12. 阶段 08:15–09:00：全量验证、APK 和交接包

### 08:15–08:25：静态和单元验证

~~~powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
~~~

任何失败必须记录到 handoff report，不能只说“构建完成”。

### 08:25–08:35：Android release

在 D 盘工具链中执行：

~~~powershell
$root = '<PROJECT_ROOT>'
$tool = '<TOOLS_ROOT>'
$env:JAVA_HOME = "$tool\jdk-17"
$env:ANDROID_SDK_ROOT = "$tool\android-sdk"
$env:ANDROID_HOME = "$tool\android-sdk"
$env:GRADLE_USER_HOME = "$tool\gradle"
$env:PUB_CACHE = "$tool\pub-cache"
$env:TEMP = "$tool\tmp"
$env:TMP = "$tool\tmp"
& "$tool\flutter\bin\flutter.bat" build apk --release
~~~

若没有正式 release keystore，只能交付 debug/unsigned 或使用现有受保护签名配置，并明确标注；不能生成新的密钥代替已发布应用。key.properties 和 keystore 只放 <SECRETS_DIR>，不进入 ZIP。

### 08:35–08:43：产物验证

验证：

- APK 存在且大小合理。
- versionName/versionCode 正确。
- APK Signature Scheme v2/v3 验证。
- SHA-256。
- 包内无 key.properties/jks/p12。
- source ZIP 与 APK 版本对应。

### 08:43–08:55：生成交接 ZIP

调用：

~~~powershell
.\scripts\package-iteration-handoff.ps1
~~~

最终放置：

~~~text
<DESKTOP>\ZCode-Control-9H-Iteration-Handoff-20260911.zip
~~~

ZIP 结构必须类似：

~~~text
ZCode-Control-Iteration-Handoff/
  START-HERE.md
  AI-EXECUTION-PROMPT.md
  docs/
    ITERATION-PLAN-9H.md
    UX-NATIVE-REBUILD-SPEC.md
    AUTOMATION-SELF-TEST-PLAN.md
    FEEDBACK-AUDIT-20260910.md
    WORKBUDDY-REFERENCE.md
    HANDOFF.md
    REFERENCE-PACKAGE-NOTICE.md
  source/
    zcode-control-source.zip
  baseline/
    ZCode-Control-1.4.0-release.apk
    SHA256SUMS.txt
  feedback/current-run/
    S01...S11.jpg
  reference/workbuddy/
    workbuddy.apk
    wb_libapp.so
    wb_icons.txt
    README-REFERENCE-ONLY.md
  MANIFEST.md
  CHECKSUMS.sha256
~~~

### 08:55–09:00：交接结论

写明：

- 已完成项。
- 未完成项。
- 真实设备验收仍需用户重新授权。
- 任何协议未验证项。
- release signing 状态。
- ZIP、APK、source checksum。
- 下一步最短路径。

最终提交点：

~~~text
chore: package nine-hour native iteration handoff
~~~

## 13. 阻断处理规则

### 协议方法不存在

记录 method-not-found，切换为 unsupported/notReturned。不能猜测同名服务，也不能打开网页让用户“先同步”。

### RPC 有响应但没有 requestId

实现 single-flight + 版本/方法/epoch/response shape 过滤；如果仍不能安全关联，限制为只读并记录风险。

### 桌面端拒绝配置

保留旧值，展示安全 error code 和重试；不能把失败值留在 UI。

### create receipt 丢失

按 clientOperationId、任务索引和短时间窗口查询恢复；无法证明已创建时不自动重发。

### Relay 断线

保留草稿、缓存和已显示行；重连后 reconcile，不重复发送 pending write。

### 需要持续后台连接

只能进入用户主动开启的合规持续连接模式；不能隐藏前台服务通知。

### 视觉审查无法完成

使用 fake relay + golden 完成自动化基线；把真机截图列为手工阻断，不冒充通过。

## 14. Definition of Done

九小时结束时仅当以下全部满足，才可称为“本轮交接完成”：

- P0-NATIVE-001、P0-CREATE-002、P0-SEND-003、P0-CONFIG-004、P0-WORKBENCH-005 有代码、测试和结果。
- P1-IA-006、P1-COMPOSER-007、P1-STOP-008、P1-AUTOLOAD-009、P1-PRIVACY-010、P1-NOTIFY-011 有验收证据或明确剩余阻断。
- 首页是统一 shell；不依赖远控网页。
- 模型/思考/上下文没有虚构值。
- reducer 消除截图中的重复消息。
- stop 无确认且 request 只发一次。
- 普通界面可截图。
- 安静/持续后台行为符合 Android 规则。
- 全量自动测试和静态检查通过。
- APK 和 ZIP 已写入 Desktop，并有 SHA-256。
- WorkBuddy 参考件只在本地 ZIP reference 目录，不在源码/GitHub。
