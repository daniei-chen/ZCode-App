# 九小时执行进度

每完成一个阶段追加一段，不要覆盖已有记录。执行环境：本机 D 盘工具链（Flutter 3.47.3 / Dart 3.13.3 / JDK 17），真实仓库含 .git。

## 阶段记录

### 阶段：S0 基线冻结 + 协议真验证

- 时间：2026-09-11 00:40–01:10（挂钟）
- commit：`90be291 chore: import nine-hour iteration planning docs` → 本阶段 commit `chore: freeze native iteration baseline and protocol evidence`
- 改动文件：`scripts/package-source.ps1`（剥离 iOS 生成文件/ephemeral）、`scripts/package-iteration-handoff.ps1`（移除个人目录默认值，改为必填参数）、`docs/PROTOCOL-DELTA-20260911.md`（填表）、`test/fixtures/native/{verified,failures}/*.json` + `README.md`
- 完成的验收 ID：P1-LEAK-015（两处泄露已修，未进 git 历史）；协议验证覆盖 P0-SUB-002（订阅 ack schema）、P0-CONFIG-007（thought 动态数组 + `max`/`high` 常量、setModel/setThoughtLevel 独立方法、命令回执六值 status）、上下文字段（`projection.contextUsed/contextWindow`）
- 通过的测试：基线 `flutter analyze` 0 issues；`flutter test` **548 passed / 0 failed**（BASELINE-FAIL 清单为空）
- 未完成：`getTaskTokenUsage`/`getAppUsageStats` 响应字段未逐项展开（标 PARTIAL，UI 只用显式 allowlist）；真实桌面回执待真机
- 阻断：无
- 下一阶段是否可开始：是

### 阶段：

- 时间：
- commit：
- 改动文件：
- 完成的验收 ID：
- 通过的测试：
- 未完成：
- 阻断：
- 下一阶段是否可开始：

### 阶段：S1 Bootstrap / 四层 readiness / 响应路由 / epoch / 订阅 ack

- 时间：2026-09-11 01:10–01:55（挂钟）
- commit：`feat: add single native bootstrap coordinator and readiness state`
- 改动文件：新增 `lib/native/bootstrap/native_bootstrap_state.dart`（Transport/Agent/Workspace/Conversation 四层枚举 + NativeBootstrapState + NativeStatusKind 分层文案）、`lib/native/bootstrap/native_bootstrap_coordinator.dart`（`nativeBootstrapProvider`/`nativeCanSendProvider`）、`lib/relay/command_receipt.dart`（六值 status 回执解析）、`lib/relay/conversation_subscription.dart`（订阅 ack 解析与谓词）；修改 `lib/relay/relay_bridge.dart`（删除按 seq 配对的 `_pendingResponses/awaitResponse` 死代码；`subscribeConversation`/`subscribeSessionsIndex` 改为等待 ack 的 single-flight 请求；删除 `conversationRows`/`conversationPlans`/`sendConversationCommand` 三个 fire-and-forget 泄漏源；`sendConversationCommandReceipt` 支持调用方 commandId、记录 `lastCommandReceipt`；`_commandAccepted` 识别 duplicate 为幂等成功）、`lib/state/relay_source.dart`（状态含 `connectionEpoch`/`agentPhase`/`agentFailure` 与 `bootstrap` 合成；连接完成后主动握手 Agent；传输失败重置 agentPhase；`epochOf`、`lastCommandReceipt`）、`lib/state/conversation.dart`（`subscribed` 布尔→`subscription` 相位 + `subscriptionId` + `subscriptionEpoch`；`_attachRealtime` 等 ack、epoch 不符自动重绑 stream）、`lib/ui/conversation_page.dart`/`new_conversation_page.dart`（可发送与状态文案改由 readiness 推导）、`analysis_options.yaml`（排除 gitignored `tools/`）
- 完成的验收 ID：P0-NATIVE-001、P0-SUB-002、P0-RESP-003（泄漏源移除 + 死代码删除）、P0-REBIND-004（epoch 感知重绑，S3 补全自动触发）
- 通过的测试：`flutter analyze` 0 issues；`flutter test` 565 passed（新增 `test/native_bootstrap_state_test.dart` 17 例：分层状态/最低未就绪层文案/canSend 需 ack/nextEpoch 重置/ack 谓词不匹配回执与推送/六值回执）
- 未完成：UI 单一 primary slot、stop 去确认在 S3；连接层"S01/S02 矛盾态 fixture 复现"以单测覆盖，widget/fake-relay 复现在 S7
- 阻断：无
- 下一阶段是否可开始：是

### 阶段：S2 统一 ConversationShell + draft/create 幂等

- 时间：2026-09-11 01:55–02:35（挂钟）
- commit：`feat: unify draft and existing sessions in native conversation shell`
- 改动文件：`lib/ui/conversation_page.dart`（`sessionId`/`workspacePath` 可空 → draft 模式；identity 为可变状态，创建成功/抽屉切换原地更新，不再 push/pushReplacement；`_createFromDraft` 使用 clientOperationId 作为 v4 commandId、回执丢失时刷新 task index 并按 `CreateRecovery` 找回、失败展示回执 reasonCode 并保留草稿；draft 正文为紧凑提示 + 工作区 chip + composer；`ConversationDrawer` 改为回调 `onNewConversation`/`onSelectSession`）、`lib/ui/native_device_view.dart`（直接返回 draft shell）、删除 `lib/ui/new_conversation_page.dart`、`lib/state/create_recovery.dart`（新增，纯函数）、`lib/state/session_index.dart`（`SessionRanking`：pinned > running/待审批 > 最近活动，稳定 tie-break）、`lib/relay/relay_bridge.dart` + `lib/state/relay_source.dart`（createConversation 透传 commandId）
- 完成的验收 ID：P1-IA-009（首屏统一 shell、无独立新对话页、create 幂等与恢复）、P2-HISTORY-018（排序规则，分组视觉在 S6）
- 通过的测试：analyze 0 issues；`flutter test` 573 passed（新增 `test/native_shell_test.dart` 7 例；`test/session_index_test.dart` 中“待办不置顶”按 UX 规格 §3.2 改为“待审批与 running 同组置顶”并加 pinned 用例——这是规格驱动的有意变更：首屏为 ConversationPage draft/无“开始对话”按钮与大图标/禁用态提示为分层文案/抽屉“新建”不增加 route/CreateRecovery 三例/SessionRanking 稳定排序）
- 未完成：draft 态的模型/思考/上下文 chip 需要工作区默认配置来源（S4 处理）；抽屉视觉分层在 S6
- 阻断：无
- 下一阶段是否可开始：是

### 阶段：S3 ConversationReducer / 重连重绑 / send-stop 状态机 / 单一主动作

- 时间：2026-09-11 02:35–03:20（挂钟）
- commit：`fix: unify conversation reducer and single-slot composer actions`
- 改动文件：新增 `lib/models/conversation_identity.dart`（五级 canonical key：rowId→entityId→toolCallId→messageId/clientOperationId→低置信度 kind+origin+2s 桶+归一化文本哈希）、`lib/state/conversation_reducer.dart`（所有 initial/older/live/refresh/optimistic 输入唯一入口；同 identity 替换不追加；无 id 推送与带 rowId 刷新互相升级不重复；乐观用户行由带 `sourceCommandId` 的官方 userInput 行替换；空 refresh 不清行；排序 rowId→createdAt→到达序，无 id 行不再排到顶部）；修改 `lib/state/conversation.dart`（`_mergeLive`/`load`/`loadOlder` 全部走 reducer 且 refresh 改为合并而非整体替换；`SendPhase` 状态机 idle→preparing→pendingReceipt→streaming→completed|failed，发送带 clientOperationId 并插入乐观行，失败撤回乐观行并显示回执 reasonCode；删除 450/700/400ms 三处固定延时，改为“accepted 后 3s 内无实时行才 reconcile 一次”；stop 一个连接 epoch 只发一次（`stopEpoch` 守卫），失败允许重试；`ref.listen(relaySourceProvider)` 感知 epoch 变化→取消旧 bridge 的 stream 订阅、清空 ack、Agent ready 后自动 `_attachRealtime` 重绑）、`lib/relay/relay_bridge.dart` + `lib/state/relay_source.dart`（sendText 透传 commandId）、`lib/ui/conversation_page.dart`（删除停止 AlertDialog，改为 haptic + 直接发送；composer 尾部单一 `_PrimaryAction` 槽位：stopping/stop/sending/send/attach/disabled 六态互斥，44dp 触控目标，`canStop` 改为真实运行信号）
- 完成的验收 ID：P0-REDUCER-005、P0-TIMER-006、P0-REBIND-004（自动重绑）、P1-COMPOSER-010
- 通过的测试：analyze 0 issues；`flutter test` 590 passed（新增 `test/conversation_reducer_test.dart` 11 例：F06 重复行→1、推送先到/刷新先到互相升级、乐观行替换、空刷新不清行、分页边界去重、无 id 行按时间排序、S02 两个真实相同文本轮次保持独立、S05 场景重放不产生第二气泡；`test/composer_action_test.dart` 6 例：六态决策表、渲染时仅一个主动作且为 stop、点击 stop 无 AlertDialog 且触发一次请求、状态行显示“会话已就绪”）
- 未完成：F12 双击 stop 只发一次请求的 notifier 级验证与 F13/F15 重连重绑端到端在 S7 用 fake relay 覆盖
- 阻断：无
- 下一阶段是否可开始：是

### 阶段：S4 RuntimeConfigRepository（真协议）

- 时间：2026-09-11 03:20–04:00（挂钟）
- commit：`feat: centralize verified runtime config discovery and updates`
- 改动文件：`lib/state/conversation_config.dart`（重写：验证路径优先——`settings.model.current{providerId,modelId}`、`settings.model.available[]{ref,label,providerLabel,contextWindow,reasoning{enabled,levels[]},disabledReason}`、`settings.thoughtLevel{enabled,current,available[]}`、`projection.contextUsed/contextWindow`（window 0 视为未返回）、`runtime.contextUsage{used,size}`、`runtime.stateRevision`；legacy 形状保留为回退；每个集合字段带 `ConfigFieldState` returned/empty/notReturned 出处；`ThoughtOption{value,label,description}`；`mergeUsage` 只补上下文缺口）、`lib/relay/service_call_result.dart`（新增，保留失败原因）、`lib/state/relay_source.dart`（`callService` 带错误原因；`applySessionModel`→`zcode-session.setModel` 只发 model；`applySessionThoughtLevel`→`zcode-session.setThoughtLevel` 只发 thought + expectedRevision；回执谓词识别 `{changed,sessionId}`）、`lib/state/conversation.dart`（`updateRuntimeConfig`：先按权威快照本地校验（目录内/未禁用/思考级别在返回选项内），单独切模型或单独切思考，`method_not_found` 时才回退组合命令；失败保留旧快照并显示桌面端 reasonCode；`loadRuntimeConfig` 刷新失败保留上次快照）、`lib/ui/conversation_page.dart`（删除硬编码 `none/low/medium/high/xhigh` 与标签表；思考 sheet 只显示快照返回的选项，未返回/空列表时当前值只读并说明；模型 sheet 区分“未返回目录”与“返回空目录”，禁用模型显示 `disabledReason` 不可点；chip 与 sheet 共用同一 `runtimeConfig`）
- 完成的验收 ID：P0-CONFIG-007
- 通过的测试：analyze 0 issues；`flutter test` 603 passed（新增 `test/runtime_config_repository_test.dart` 13 例：S0 fixture 全字段解析、F09 选项未返回只读、F10 contextWindow 0→未返回、runtime.contextUsage 回退、quota 不冒充上下文、ServiceCallResult、本地校验拒绝目录外/禁用模型且不发写请求、F11 拒绝保留旧值并显示 reasonCode、模型-only 只调 setModel、思考-only 只调 setThoughtLevel 且带 revision、同值 no-op；旧 `conversation_config_test.dart` legacy 形状 3 例继续通过）
- 未完成：draft 态的模型/思考 chip（需工作区默认配置读路径，未验证，保持隐藏）；真实桌面回执待真机
- 阻断：无
- 下��阶段是否可开始：是

### 阶段：S5 Workbench 收敛为一条原生数据链

- 时间：2026-09-11 04:00–04:40（挂钟）
- commit：`feat: make workbench and settings data native-first and auto-loading`
- 改动文件：`lib/ui/panels_page.dart`（`PanelsPage.nativeScope` 选定 relay 设备并携带分层状态；九宫格对 relay 设备一律路由到原生页面——usage/skills/MCP/plugins/commands/subagents/hooks/memory 走 `SettingsPanelPage`，model 走新的 `NativeModelPage`；**删除跨设备 fold**：有 relay 设备时不再合并任何被动 snapshot，被动路径只留给不支持 Relay 的旧设备；副标题改为 readiness 文案；顺带修复 `_PanelCard` 同时给 `Material` 传 `shape` 与 `borderRadius` 的潜伏断言）、`lib/ui/native_model_page.dart`（新增：按设备活动/最近会话通过 `zcode-session.readSession` 读模型目录、当前模型/思考/上下文、禁用原因，来源与时间可见；ready 后自动加载）、`lib/ui/agent_usage_page.dart`/`skills_page.dart`/`mcp_servers_page.dart`/`plugins_page.dart`/`agent_resource_page.dart`（pending intent：页面先开、Agent 握手后自动加载一次；usage 页修复 `setState` 箭头闭包返回 Future 的断言）、`lib/l10n/app_zh.arb` + `app_en.arb`（11 条“在远控页打开一次…”占位文案替换为本机状态文案，`lib/l10n/*.dart` 已重新生成）
- 完成的验收 ID：P0-WORKBENCH-008（双数据链收敛、跨设备隔离、S08–S11 占位消失）、P1-AUTOLOAD（页面进入自动加载）
- 通过的测试：analyze 0 issues；`flutter test` 608 passed（新增 `test/workbench_autoload_test.dart` 5 例：nativeScope 优先就绪设备/回退首个 relay 设备/无 relay 设备为 null；relay 设备点“使用统计”进入 `AgentUsagePage` 而非被动 `UsagePanelPage`、副标题为分层状态、全页无“远控页”文案；WebView 旧设备保留被动回退且无“远控页”文案）
- 未完成：`WorkbenchRepository` 未另起新类——现有 per-resource notifier（skills/mcp/plugins/agentCapabilities）已按设备隔离并承担该职责，pending intent 以 `listenManual` 实现；六态 UI（stale + last sync）在 S6 视觉阶段补齐
- 阻断：无
- 下一阶段是否可开始：是

### 阶段：S6 后台 / 通知 / 截图 / 日志 / usage 脱敏策略

- 时间：2026-09-11 04:40–05:05（挂钟）
- commit：`fix: make background, notification, screenshot and logging policies explicit`
- 改动文件：`lib/services/usage_metric_policy.dart`（新增：显式 allowlist——只放行数值/布尔且键名为已知指标或以 tokens/count/percent/seconds/ms/total/used/remaining/budget/enabled 结尾；`*Id`/`*Ids`、sessionid/accountid/path/email/name/url/hash/token 等标识片段一律拒绝；字符串永不渲染）、`lib/ui/agent_usage_page.dart`（改用该策略，删除“key 含 session 即指标 + ≤80 字符 String 放行”的模糊规则）、`lib/state/keepalive.dart`（持续连接模式默认 **关闭** = 安静模式，与 `DeviceStore` 持久化默认一致；用户显式开启才启动前台服务）、`lib/l10n/app_zh.arb`/`app_en.arb`（开关改名“持续连接（前台服务）”，副标题写明前台通知代价与安静模式行为）
- 截图策略（P1-PRIVACY-013���：静态扫描确认 `lib/` 与 `android/app/src` 中**不存在** FLAG_SECURE/setSecure/WINDOW_SECURE；新增测试守门防止将来无意加入。“不允许截图”的根因不在本应用源码，列入真机复现待办（重点：local_auth 弹窗期间与 MIUI 策略）。
- 通知（P1-NOTIFY-014）：事件通道已是 `*_quiet_v2` IMPORTANCE_LOW（无声/无震动/不 heads-up）；前台服务通道 `zr_keep_silent_v2` IMPORTANCE_LOW 且仅在持续连接模式启动。
- 完成的验收 ID：P1-USAGE-011、P1-NOTIFY-014（默认安静）、P1-PRIVACY-013（代码侧：无全局禁截屏 + 守门测试）
- 通过的测试：analyze 0 issues；`flutter test` 614 passed（新增 `test/security_policy_test.dart` 6 例：指标放行/标识拒绝/���符串拒绝、持续连接默认关闭与决策表、源码无 FLAG_SECURE、relay 层不打印 payload/凭据）
- 未完成：UI tokens/抽屉视觉分层（原 S6 视觉部分）未单独做——本轮已在 shell/composer/工作台空态中落地 8dp/44dp 与状态 pill 语义，其余视觉打磨列为 P2 剩余项
- 阻断：无
- 下一阶段是否可开始：是

### 阶段：S7 Fake Relay + 故障注入 F01–F16 + 端到端 flow

- 时间：2026-09-11 05:05–05:50（挂钟）
- commit：`test: add native conversation contract fixtures and failure-injection coverage`
- 改动文件：新增 `test/fake_relay/fake_relay_server.dart`（内存 relay + 桌面端替身：auth 握手、workspace list（含 tasks[]）、bridge open、二进制 agent RPC 响应帧 `04 02`、请求形推送帧 `04 04`、每次 connect 发新 socket、可脚本化 handler、记录全部出站 RPC 与 stop/create/send 计数）、`test/fake_relay/failure_injection_test.dart`（8 例）、`test/fake_relay/failure_injection_more_test.dart`（7 例）；修复 `lib/state/relay_source.dart`（`fetchRows` 谓词把显式 `rows: []` 当有效响应——此前空会话会等到 25s 超时才失败）、`lib/state/conversation_config.dart`（`mergeUsage` 中快照明确返回“空目录”时不再被 usage 的 notReturned 覆盖）
- 故障注入覆盖：F01 握手延迟（shell 保持 connecting）、F02 relay ready 但 hello 未回（agentHandshaking，不可发送，文案“已连接，正在初始化 Agent”）、F03 订阅失败（sessionSubscribeFailed，传输层仍 relayReady，失败层=conversation）、F04 create 回执丢失但索引有新会话（按 CreateRecovery 找回，不重复 create）、F05 create 丢失且无新会话（草稿保留）、F06 重复推送行→1 条、F07 旧 epoch 的订阅尝试不能生效、新 bridge 自动重绑且推送恢复、F08 目录空（empty≠notReturned）、F09/F10（单测已覆盖，此处再验 window 0→未返回）、F11 配置拒绝保留旧值并显示 reasonCode 且不回退组合命令、F12 双击 stop 只发一次、F13 断线后行保留、恢复连接后重绑成功且更新替换不追加、F14 method not found→unsupported、F15（与 F07 合并验证）、F16（多设备隔离由 S5 `PanelsPage.nativeScope` 测试覆盖）；另有 happy path：四层顺序就绪、发送乐观行被带 `sourceCommandId` 的官方行替换、一次发送一条回执
- 完成的验收 ID：P0-NATIVE-001/P0-SUB-002/P0-RESP-003/P0-REBIND-004/P0-REDUCER-005/P0-TIMER-006/P0-CONFIG-007 的契约级验证
- 通过的测试：analyze 0 issues；`flutter test` **629 passed / 0 failed**
- 未完成：golden 测试未建立（本环境无既有 golden 基线，自行生成的基线无法证明视觉正确性，列为剩余项）；integration_test 目录未新增（fake relay 已在 unit 层驱动全流程，无需设备）
- 阻断：无
- 下一阶段是否可开始：是

## 最终摘要

- 实际用时：约 4 小时 40 分钟挂钟（2026-09-11 00:40 起，S0–S8 全部完成），低于 540 分钟预算；每阶段独立 commit、闸门全部通过后再进入下一阶段
- 迭代 commit 序列（基线 8c79d3d 之上）：`90be291` 导入规划文档 → `8c33bb8` 基线冻结+协议证据 → `06b0cb3` 四层 readiness/响应路由/订阅 ack → `4339490` 统一 ConversationShell → `5ed1459` reducer/重绑/单槽位 → `05f8427` 真协议 RuntimeConfig → `0747073` Workbench 收敛 → `2490cc3` 策略 → `d9ab0d7` fake relay 故障注入 → `fa84dc1` 格式化+版本 1.5.0+8 → 本 commit 打包
- analyze：`flutter analyze` **0 issues**；`dart format --set-exit-if-changed lib test integration_test` **通过**
- unit/widget：`flutter test` **629 passed / 0 failed**（基线 548 → +81：bootstrap 状态 17、shell 7、reducer 11、composer 6、runtime config 13、workbench 5、安全策略 6、fake relay 契约 15、排序变更 1）
- golden：**未建立**——本环境没有既有 golden 基线，自行生成的基线只能证明“与自己一致”，不能证明视觉正确；列为剩余项（需在真机截图验收后一起建立）
- contract/integration：fake relay（`test/fake_relay/`）驱动真实 `RelaySourceNotifier`/`ConversationNotifier` 完成 F01–F15（F16 多设备隔离由 `PanelsPage.nativeScope` 测试覆盖）；未新增 `integration_test/`（无需设备即已覆盖全流程）
- Android release：`flutter build apk --release` 成功；`com.zcode.control` versionName **1.5.0** versionCode **8**；71.9 MB；`apksigner verify --verbose --print-certs`：**Verifies，v2 scheme = true**，1 个 signer，证书与 1.4.0 基线 APK **同一密钥**（未新建密钥）；签名材料只在 `<SECRETS_DIR>`，`android/key.properties` 被 gitignore
- APK SHA-256：**63FABD02465F7A389EAC6DABD972DCB685161C3EF828800F7CB9468DB92A7E1A**
- Desktop ZIP：`<DESKTOP>\ZCode-Control-9H-Iteration-Result-20260911.zip`（224.9 MB，45 entries；`pwsh -File scripts/package-iteration-handoff.ps1` 生成；含 release/1.5.0 APK、baseline/1.4.0 APK、源码包 277 entries、11 张反馈图、WorkBuddy 参考件；本项目自身 UI 截图单独标注为 `reference/zcode-control-ui/`）
- ZIP SHA-256：**F18673B9AC200B0E7133A5CA59AD966361B8B85A0FAC9BD59B3BC5994ED876CD**（同目录 `.sha256` 文件）；包内 MANIFEST 记录打包时 HEAD = 62a64ff
- 包内扫描：无 key.properties/jks/p12/.git/build；内层源码包无 `Generated.xcconfig`/`ephemeral/`/`tools/`；真实个人标识（微信目录 ID）在包内**零命中**（仅计划文档保留扫描规则字面量）
- 真机是否执行：**否**（用户已要求停止；未连接 ADB/无线调试，未打开任何远控 URL/WebView，未读取或输出 sid/hash/token）
- WebView 是否打开：**否**
- secrets scan：**pass**——跟踪文件中零真实凭据；仅命中三处已知安全占位（CI `release.yml` 从 secret 打印模板、两处测试用的明显假 sid）；无 key.properties/jks/p12/tools/ 入库；`ios/Flutter/Generated.xcconfig` 与 `ephemeral/` 已从源码包剥离；打包脚本不再含个人目录
- 协议未验证项（如实）：`getTaskTokenUsage`/`getAppUsageStats` 响应字段未逐项展开（PARTIAL，UI 用显式 allowlist）；所有写方法（setModel/setThoughtLevel/createSession/sendText/stop）为 **app.asar zod schema 静态验证 + fake relay 契约**，**尚无真实桌面回执**
- 剩余风险 / 真机待办：
  1. “不允许截图”根因——源码无 FLAG_SECURE，必须新 APK 真机复现（重点 local_auth 弹窗期与 MIUI）
  2. Relay 真机握手、create/send/reply/stop、切后台恢复、MIUI 电池优化、生物识别边界、锁屏通知脱敏、字体 200%/TalkBack
  3. 意外断线当前按既有语义视为终态失败（不自动重试），恢复依赖回前台/用户重连；是否改为非终态自动退避需真机观察后决定
  4. draft 态的模型/思考 chip 需要工作区默认配置的读路径（`readWorkspaceState`/`resolveRuntimeModelForV4` 未验证），当前隐藏
  5. golden 基线与 P2 视觉打磨（抽屉分层视觉、tokens 收口）
- 下一步最短路径：用户重新授权后，安装 `release/ZCode-Control-1.5.0-release.apk`，按 `docs/AUTOMATION-SELF-TEST-PLAN.md` §9 清单逐项真机验收，验收过程中**不得**打开同一 sid/hash 的网页远控页

## 增量收口记录（本地、未连接远程 ZCode）

- 时间：2026-09-11（本地继续收口）
- 改动：移除“通知”底部根导航，保留通知历史与审批徽标并改由设置中心上下文入口进入；通知点击可携带 `deviceId|sessionId` 直达对应会话；Workbench 优先跟随当前设备且不再跨设备合并快照；会话拒绝/回执按 session 隔离；运行时配置显式空目录可覆盖旧目录；资源列表刷新失败时保留缓存并显示 stale/retry 状态；修复通知 payload 的事件 taskId 取值；补充 root-tab、通知、Workbench 与运行时配置回归测试。
- 自动化：`flutter analyze` 0 issues；`dart format --output=none --set-exit-if-changed lib test integration_test` 通过；`flutter test --reporter compact` **640 passed / 0 failed**；`flutter build apk --release` 成功；`apksigner verify --verbose --print-certs` 通过（v2=true，单签名）。
- APK：`build/app/outputs/flutter-apk/app-release.apk`，SHA-256 `B5DDBCA28450E9891F069F738A3610E0D3D85BD7CAB855E87A19ECEAED3FD09C`。
- 集成测试：Android 模拟器安装阶段可启动构建，但设备反复变为 offline，随后 `VmServiceDisappearedException`，因此本次**不宣称 integration smoke 通过**；代码单测、fake relay 契约测试和 release 构建结果独立有效。
- 边界：本阶段没有调用远程 ZCode、没有打开远控 URL/WebView、没有读取或输出 sid/hash/token；仅在本地仓库和本地模拟器上操作。
