# ZCode Control 9 小时迭代 · 最终执行计划（v2 定稿）

- 日期：2026-09-11
- 输入：原交接包审计 + 第二轮独立审计（响应归属/重连重绑/usage 泄露/跨设备 fold）+ 11 张真机截图 + 全量源码审阅
- 执行仓库：`<PROJECT_ROOT>`（含 .git，HEAD = 8c79d3d）
- 总预算：540 分钟，9 个阶段，每阶段有闸门（Gate）和独立 commit

---

## 〇、环境事实（2026-09-11 实测，推翻"沙箱审计"的三个前提）

| 事实 | 状态 | 对计划的影响 |
|---|---|---|
| Flutter 3.47.3 stable + Dart 3.13.3 | ✅ `<TOOLS_ROOT>\flutter`，env 模板可运行，与 CI 版本一致 | **无需下载工具链**，第一小时省下的时间全部投给协议勘探 |
| JDK 17 / Android SDK / Gradle / pub-cache | ✅ 同在 `.toolcache` | release 构建可执行 |
| apksigner | ✅ build-tools 35.0.0 与 36.0.0 都有 | 签名可以做**完整验证**，不是只看签名块存在 |
| 真实源码仓库（含 .git） | ✅ HEAD = 8c79d3d `feat: complete native workbench conversation flow` | **每阶段独立 commit 可真实执行**；lib/ 树与交接包 zip 快照逐文件一致 |
| app.asar | ✅ `<ZCODE_INSTALL>\resources\app.asar`（307 MB） | 协议可以**真验证**：模型/思考/上下文写协议、订阅 ack 形状都必须在本轮拿到证据，不再默认只读 |
| release 签名材料 | ✅ `<SECRETS_DIR>\`（jks + password） | 可交付正式 release APK；材料绝不入库、不进 ZIP |
| Python 3.12 / Node 24 | ✅ | asar 解包用 Python 直读即可，无需额外安装 |
| java/flutter 不在 PATH | ⚠️ | 所有 flutter/dart 命令必须走 §A.1 环境模板 |

> 工作区现状：`git status` 只有未跟踪的 9 份交接规划文档 + 已修改的 `scripts/package-source.ps1`。lib/ 与基线完全一致——这是干净起点，Phase 0 先把它们作为规划文档提交冻结。

---

## 一、统一问题总账（两轮审计合并，全程以此为准）

| ID | 问题 | 一句话根因 | 修复阶段 |
|---|---|---|---|
| P0-NATIVE-001 | "已连接"却不能发（readiness 假阳性·上层） | `relay_source.dart:210` RelayPhase.ready 即置 `live`，Agent/workspace/session 三层未参与 | 阶段 1 |
| P0-SUB-002 | "已订阅"可能没订阅（readiness 假阳性·下层） | `subscribeConversation` 发出 RPC 即返回 true，不等桌面端 `ack.subscriptionId` | 阶段 1 |
| P0-RESP-003 | RPC 响应归属不可靠/串包 | `where` 只按"有 value/value 是 Map"匹配；fire-and-forget 迟到响应被下一请求吃掉；`_pendingResponses` 按 seq 配对是死代码 | 阶段 1 |
| P0-REBIND-004 | 重连后实时流断 | `ConversationNotifier._subscriptions` 缓存旧 bridge 的 subscription，不感知 bridge 重建 | 阶段 1+3 |
| P0-REDUCER-005 | 消息重复 / live 行被覆盖 | `_mergeLive` 只认 rowId/entityId/toolCallId；`load(refresh:true)` 整体替换 rows；无统一 reducer | 阶段 3 |
| P0-TIMER-006 | 450/700/400ms 固定延时刷新是竞态 | 用"猜桌面处理时间"代替协议状态 | 阶段 3 |
| P0-CONFIG-007 | 模型/思考/上下文假权威 | 硬编码 `none/low/medium/high/xhigh`（真值含 `max`）；`updateRuntimeConfig` 强制三字段齐发；无 provenance/revision/stale | 阶段 4 |
| P0-WORKBENCH-008 | 工作台两套数据链 + 跨设备混合 | 底部工作台走被动 `panelDataProvider`；`PanelsPage` 把所有设备 snapshot fold 成一个全局态 | 阶段 5 |
| P1-IA-009 | 独立新对话页 + create 无幂等恢复 | `NativeDeviceView→NewConversationPage→pushReplacement`；失败只看 `sessionId==null` | 阶段 2 |
| P1-COMPOSER-010 | stop/send 双主按钮 + 停止二次确认 | `conversation_page.dart:760` 两个 IconButton；`:391` AlertDialog | 阶段 3 |
| P1-USAGE-011 | usage 脱敏误放行 | `_isMetricKey` 认 key 含 `session` 即指标 + 允许 ≤80 字符 String → sessionId 可能上屏 | 阶段 6 |
| P1-DOCS-012 | HANDOFF.md "✅" 污染 | 多项标记完成与 S01–S11 矛盾 | 阶段 0（登记）+ 阶段 8（重写） |
| P1-PRIVACY-013 | "不允许截图"根因未定位 | 源码**无任何 FLAG_SECURE**；嫌疑：local_auth 弹窗期系统行为 / MIUI 策略 | 阶段 6（代码侧）+ 真机待办 |
| P1-NOTIFY-014 | 通知需安静/持续两模式 | 现有 KeepAliveService 常驻通知，默认模式未分层 | 阶段 6 |
| P1-LEAK-015 | 源码包个人信息泄露 | `package-iteration-handoff.ps1:8` 含 wxid 微信目录；`ios/Flutter/Generated.xcconfig`+`ephemeral/*.env` 含本机绝对路径 | 阶段 0（修打包白名单） |
| P1-REF-016 | WorkBuddy 参考图贴错标签 | `reference/workbuddy/ui-reference/` 4 张图是本项目 ZREMOTE 截图，非 WorkBuddy | 阶段 8（打包时纠正） |
| P2-UI-017 | 视觉层级/信息密度 | 巨型居中空态、缺 tokens 统一 | 阶段 6 |
| P2-HISTORY-018 | 抽屉需 device→workspace→session 分组 | 现为简单列表 | 阶段 2（纯函数）+ 阶段 6（视觉） |

---

## 二、九小时总排程

| 时间 | 分钟 | 阶段 | 闸门 |
|---|---:|---|---|
| 00:00–00:40 | 40 | S0 基线冻结 + app.asar 协议真验证 | G0 |
| 00:40–01:45 | 65 | S1 Bootstrap / 四层 readiness / 响应路由器 / epoch | G1 |
| 01:45–02:40 | 55 | S2 统一 ConversationShell + draft/create 幂等 | G2 |
| 02:40–03:40 | 60 | S3 Reducer / 重连重绑 / send-stop 状态机 | G3 |
| 03:40–04:45 | 65 | S4 RuntimeConfigRepository（真协议） | G4 |
| 04:45–05:45 | 60 | S5 Workbench 收敛为一条原生数据链 | G5 |
| 05:45–06:35 | 50 | S6 UI/IA + 后台/通知/隐私策略 | G6 |
| 06:35–08:10 | 95 | S7 Fake Relay + F01–F16 + 单测/widget/golden/integration | G7 |
| 08:10–09:00 | 50 | S8 analyze/test/build/sign/scan/handoff | G8 |

---

## 三、阶段详规

### S0（00:00–00:40）基线冻结 + 协议真验证

**00:00–00:08 环境与仓库定格**
- 用 §A.1 模板记录 `flutter --version`、`dart --version` 输出（已预验：3.47.3 / 3.13.3）。
- 在真实仓库查看 `git diff scripts/package-source.ps1` 并确认改动内容（打包脚本调整），连同 9 份未跟踪规划文档一起提交：
  ```bash
  git add docs/AI-EXECUTION-PROMPT.md docs/AUTOMATION-SELF-TEST-PLAN.md docs/FEEDBACK-AUDIT-20260910.md \
          docs/HANDOFF-START-9H.md docs/ITERATION-PLAN-9H.md docs/PROGRESS-9H.md docs/PROTOCOL-DELTA-20260911.md \
          docs/REFERENCE-PACKAGE-NOTICE.md docs/UX-NATIVE-REBUILD-SPEC.md \
          scripts/package-source.ps1 scripts/package-iteration-handoff.ps1
  git commit -m "chore: import nine-hour iteration planning docs"
  ```
- 此 commit 后 HEAD 即"迭代基线"，后续所有阶段 commit 叠加其上，真实历史保留 8c79d3d。

**00:08–00:15 基线体检（后台）**
- 后台跑 `flutter analyze` 与 `flutter test`（各约 1–2 分钟），同时开始协议勘探。
- 失败项登记为 BASELINE-FAIL，不归咎后续改动。

**00:15–00:33 app.asar 协议真验证（本机独有优势，最高优先级）**

解包（Python 直读 asar：8 字节头 + JSON index + 文件区）：
```bash
python - <<'PY'
import json, struct
f = open(r"<ZCODE_INSTALL>\resources\app.asar","rb")
f.seek(4); hlen=struct.unpack("<I",f.read(4))[0]
idx=json.loads(f.read(hlen).decode())  # 先拿文件索引，再按 offset+size 抠出目标 js chunk
open(r"D:\tmp\asar-index.json","w",encoding="utf8").write(json.dumps(idx,ensure_ascii=False,indent=1))
PY
```
按索引抽取 `out/host/chunk-*.js` 等目标 chunk 后，用 rg 逐项确认并填写 `docs/PROTOCOL-DELTA-20260911.md` 方法表：

| # | 待验证项 | 搜索线索 | 产出 |
|---|---|---|---|
| 1 | `zcode-session.readSession` 响应中 model/thought/context/catalog 的确切路径与字段名 | `readSession`、`thoughtLevel`、`modelCatalog`、`contextWindow` | verified/session_snapshot_with_runtime.json |
| 2 | **思考级别真值枚举**（截图已见 `max`，硬编码 5 档必错） | `thoughtLevel` 邻近的 zod enum / switch 分支 | verified/thought_options_by_model.json |
| 3 | `zcode-session.setModel` / `setThoughtLevel` / `setWorkspaceDefaultModel` / `resolveRuntimeModelForV4` 参数 schema——与 `switchModelConfig` 命令二选一或并存 | `setThoughtLevel`、`resolveRuntimeModelForV4` | 决定阶段 4 写路径 |
| 4 | `subscribeConversationV4` 的 ack 形状（`{ack:{subscriptionId,mode,logEpoch}}`，见协议文档 §8.7）——订阅确认的依据 | `subscribeConversationV4`、`subscriptionId` | P0-SUB-002 的判据 |
| 5 | `createSession` / `sendText` / `stop` / `resolveInteraction` 回执与错误形状（accepted/rejected/noop） | `sendConversationCommandV4`、`commandId`、`accepted` | verified/create_receipt.json 等 |
| 6 | `usage-stats.getAppUsageStats` 返回字段清单（供阶段 6 allowlist） | `getAppUsageStats` | verified/usage_stats_summary.json |
| 7 | `switchCollaborationMode`/`setFollowupMode` 等（只登记，不实现） | — | NOT-VERIFIED 清单 |

脱敏纪律：只写字段名/类型/最小 payload；sid/hash/token/完整 URL/机器名/绝对用户路径/消息正文一律不落盘。每个 fixture 配同名 .md 旁注（source version / request / response / 已验证字段 / 脱敏操作 / 预期 parser 结果）。

**00:33–00:40 收尾**
- 修 P1-LEAK-015：`package-iteration-handoff.ps1` 的 `$FeedbackDirectory` 改为参数默认空 + 运行时必填提示；`package-source.ps1` 白名单排除 `ios/Flutter/Generated.xcconfig`、`ios/Flutter/ephemeral/`。
- issue ledger（§一 表）写入 `docs/PROGRESS-9H.md` 顶部。

**Gate G0**：baseline commit 存在；analyze/test 结果已记录；≥3 项协议拿到 verified fixture；每项未验证方法明确标 NOT-VERIFIED。
**Commit**：`chore: freeze native iteration baseline and protocol evidence`

---

### S1（00:40–01:45）Bootstrap / 四层 readiness / 响应路由器 / epoch

新建：
```
lib/native/bootstrap/native_bootstrap_state.dart      # TransportPhase/AgentPhase/WorkspacePhase/ConversationPhase 枚举 + NativeBootstrapState(含 connectionEpoch/lastSuccessAt/lastFailure{layer,method,code,safeMessage}/capabilities/pendingIntents)
lib/native/bootstrap/native_bootstrap_coordinator.dart # per-deviceId 单例；启动 7 步序；单设备并发上限；pendingIntent 登记
lib/native/bootstrap/native_capability_manifest.dart   # 从 PROTOCOL-DELTA 生成的 method 表（service/method/args 版本/response selector/read-write/testedAt/fallback）
lib/native/bootstrap/native_request_receipt.dart       # requestId+epoch+status
```

响应路由器（改 `relay_channel.dart`）——本阶段最核心：
1. **删除/隔离 `_pendingResponses`/`awaitResponse(seq)` 按 seq 配对的死代码**（桌面端不回显请求序号，留着必被误用）。
2. 每个出站请求注册 `{service, method, where, epoch, completer, deadline}`；响应按 `service+method+shape+epoch` 归属；无匹配归属的响应进 orphan 队列并计数，**绝不**喂给下一个请求。
3. fire-and-forget 调用也注册（completer 允许孤儿完成 + 超时清理），迟到响应不再污染后续请求 → 根除 off-by-one。
4. per-(service,method) single-flight；并发上限沿用单设备队列。

订阅确认（P0-SUB-002）：
- `subscribeConversationV4` 改为 request→ack：等到 `ack.subscriptionId` 才置 `subscribed=true`；超时/失败置 `conversationPhase=sessionSubscribeFailed`（可重试），绝不发"假已订阅"。

epoch（P0-REBIND-004 第一半）：
- `RelaySourceNotifier._connectGeneration` 升格为公开 `connectionEpoch`，进入 `RelaySourceState`；所有 payload/phase/failure/receipt 回调带 epoch，旧 epoch 一律丢弃（现有 if 判断保留并补全到所有回调）。
- 暴露 `epochStream`；`ConversationNotifier` 在阶段 3 消费它重绑 stream。

UI 接线：
- ConversationShell 发送允许条件 = `relayReady && agentReady && workspaceResolved && conversationReady(sessionSubscribe acked || draftCreateReady)`。
- 状态文案对应具体层："正在连接桌面端/已连接，正在初始化 Agent/已连接，正在读取工作区/会话已就绪/会话订阅失败，可重试/设备不支持 native Relay"。`"原生通道已连接"`这个笼统文案删除。

单元测试：phase 转换顺序、单层失败不重置其他层、旧 epoch 丢弃、并发 connect 共享 Future、disconnect 清理、响应乱序/重复/orphan 注入。
**Gate G1**：scripted fixture 中 transport=live+agent=handshaking 时 UI 显示"正在初始化 Agent"且不可发送（S01/S02 矛盾态可复现且被区分）；orphan 响应不改变任何 pending 请求结果。
**Commit**：`feat: add single native bootstrap coordinator and readiness state`

---

### S2（01:45–02:40）统一 ConversationShell + draft/create 幂等

- `lib/ui/conversation_page.dart` 改造为 `DeviceConversationShell`：`sessionId` 可空 + `ConversationMode.draftOrExisting`；`workspacePath` 允许 bootstrap 后回填。
- `native_device_view.dart` 直接返回 shell（P1-IA-009）；`new_conversation_page.dart` 删除或降级为 DraftComposer 子组件；删除大图标欢迎布局与 `pushReplacement`。
- Draft 行为：顶部保留设备/工作区/连接态；时间线只有轻提示；composer 立即可输入；工作区未定时草稿保留、发送禁用；**创建成功原地更新 identity/标题，route 数量不变**。
- 创建幂等（P1-IA-009）：
  1. 生成 `clientOperationId`（uuid v4）；
  2. 单次写请求，等待回执（超时 T_create=8s，来自 Phase 0 verified fixture 的真实超时特征，没有证据就 8s 并登记）；
  3. 超时后按 `clientOperationId`/最近时间窗（≤60s）+ 同 workspace 查 task index 恢复；恢复成功 → 采纳 sessionId；
  4. 找不到 → 保留草稿与附件，显示"重试"；重试复用同一 operationId，不发第二条 create。
- 抽屉分组纯函数 `lib/state/workspace_grouping.dart`：路径规范化 → device→workspace→session；pinned > running/waitingApproval > updatedAt 降序；无路径入"未归类"；同名标题加短 ID 后缀；updatedAt 缺失用服务序 + sessionId tie-break。
- 路由：通知点击带 deviceId/sessionId 直达 shell；原生默认路径零 WebView。

测试：首屏 widget 树无 NewConversationPage；draft→create 成功 route 不变；F04（receipt 丢但 index 有新会话）恢复且不重复创建；F05（全丢）保留草稿；分组排序 6 例。
**Gate G2**：S07 场景（首屏）golden 对比不再出现巨型欢迎页。
**Commit**：`feat: unify draft and existing sessions in native conversation shell`

---

### S3（02:40–03:40）Reducer / 重连重绑 / send-stop 状态机

- `lib/models/conversation_identity.dart`：canonical key 五级——rowId → entityId → toolCallId → messageId/clientOperationId → session+role+timestamp bucket(±2s)+normalized content hash（低置信度，debug 可见）。
- `lib/state/conversation_reducer.dart`：唯一入口 `apply(state, ConversationEvent)`；事件源 initial/older/live/receipt/optimistic/refresh 全部走它。规则：同 key 替换不追加；assistant streaming 按版本/内容增量；receipt 只改发送状态不产生气泡；refresh 空结果不清 live 行；分页先并后排重。
- 替换三处固定延时（P0-TIMER-006）：
  - send 后 450ms 刷新 → 删除；依赖 stream；仅当 `pendingReceipt` 超过 3s 且 stream 无该行时做一次 reconcile（走 reducer 合并，不是整体替换）；
  - resolve 后 700ms → 由 permission 行的 resolved/更新事件驱动 + 同上兜底；
  - stop 后 400ms → 由 turnHeader state 变化/stopped 事件驱动。
- 重连重绑（P0-REBIND-004 第二半）：`ConversationNotifier` 监听 `epochStream`；epoch 变化 → 取消旧 `_subscriptions[key]` 并从 map 移除 → 待 coordinator `conversationReady` 后 `_attachRealtime` 重绑新 bridge stream。
- 发送状态机：`idle→preparing→pendingReceipt→streaming→completed|failed(retryable)`；每次发送 `clientOperationId`；超时不自动重发，重试需用户点击并提示可能重复。
- Composer 单一 primary action slot（按 UX 规格状态表）；paperclip 为 secondary；删除 `:391` 的停止 AlertDialog（P1-COMPOSER-010）：点击即 `stopping` + haptic，一个 epoch 内最多一个 stop request（requestId 防重），失败仅 snackbar"重试停止"。

测试：F06（重复 stream 行→1 条）；无 rowId 行五级 identity 去重；receipt 不产气泡；refresh 空不清 live；F12（双击 stop→1 请求）；F13（流中断线→行保留、恢复后 reconcile 不重复）；发送失败文本/附件保留。
**Gate G3**：S05 场景的 fixture 重放后无重复气泡；重连后 2s 内实时推送恢复到达。
**Commit**：`fix: unify conversation reducer and single-slot composer actions`

---

### S4（03:40–04:45）RuntimeConfigRepository（真协议）

前置：S0 的 fixture。若阶段 0 有 NOT-VERIFIED 残留，本阶段开头允许追加 10 分钟勘探，仍无证据 → 该写路径锁定只读。

- 新建 `lib/repositories/runtime_config_repository.dart` + `lib/models/native_runtime_snapshot.dart`：
  - 状态：loading/snapshot/modelCatalogState/thoughtOptionsState/contextState/freshness/revision/error/pendingWrite；
  - 每个字段带 provenance：`{source: readSession|getTaskTokenUsage|catalog, revision, fetchedAt, stale, unsupported/notReturned}`；
  - key = device+workspace+session；single-flight；过期响应（旧 revision）不得覆盖新 snapshot；失败不清除上次 fresh/stale 值。
- 解析器（P0-CONFIG-007）：
  - current model 与 catalog **同源**——都从同一 snapshot 读（模型 chip 与 sheet 共用此 repository，禁止 chip 读 session、sheet 扫 payload）；
  - 思考选项来自 S0 验证的真值枚举/所选模型 capabilities；硬编码 5 档删除；桌面端只回当前值（如 `max`）→ 显示只读当前值 + "可选级别未返回"；
  - context 只认 `contextUsedTokens/contextMaxTokens/autoCompactThresholdTokens`（以 S0 实际字段名为准）；缺哪个标哪个"未返回"；usage quota 永不冒充 context。
- 写路径二选一（以 S0 证据定）：
  - 若 `zcode-session.setModel`/`setThoughtLevel` 验证通过 → 单独切换、各自回执（最小 patch）；
  - 否则沿用 `switchModelConfig` 命令，但目标值必须 ∈ 当前能力，且 UI 明示"该桌面版本要求模型+思考一起提交"；
  - 流程：读 snapshot/revision → 校验目标 → patch → 等 accepted/applied/rejected → 成功后 reread 权威值；失败保留旧值 + 显示 `service/method/code` 安全文案。

测试：6 种 catalog 形状（provider-grouped/list/direct/空/缺 enabled/异常深嵌套截断）；chip/sheet 同 snapshot 断言；update rejected 无乐观永久变化；F08（catalog 空）/F09（thought 未返回）/F10（max 缺失）/F11（config rejected）。
**Gate G4**：golden 中 thought sheet 只出现权威选项；代码中 `rg "'xhigh'" lib/` 零命中（除 fixture 注释）。
**Commit**：`feat: centralize verified runtime config discovery and updates`

---

### S5（04:45–05:45）Workbench 收敛为一条原生数据链

- **快速路径优先**（一小时可见效）：`panels_page.dart` 九宫格入口直接路由到已接通原生 RPC 的页面——usage→`AgentUsagePage`、plugins→`PluginsPage`、MCP→`McpServersPage`、skills→`SkillsPage`、commands/subagents/hooks/memory/indexing→`AgentResourcePage`、model→新原生 model page（复用 S4 repository）。S08–S11 四张截图的问题在这一步消失。
- 新建 `lib/repositories/workbench_repository.dart` + `lib/models/native_resource_state.dart`：per-device+workspace 隔离的 usage/model/skills/plugins/MCP/commands/subagents/hooks/memory/indexing 状态，各带 `{state, provenance, lastSuccessAt, error}` 六态（loading/fresh/stale/empty/unsupported/transportError）。
- **消灭跨设备 fold**：`PanelsPage` 现把 `snapshots.values` fold 成全局 snapshot（A 设备模型 + B 设备 usage）——删除该路径；工作台只显示当前选中设备的数据，设备切换跟随 shell。
- relay 设备产品路径退役 `panelDataProvider` 被动扫描（保留给 WebView 兼容旧设备）。
- bootstrap 预热 + pendingIntent：coordinator ready 后自动拉取；页面先开时注册 intent，ready 后自动执行一次；页面销毁只取消自身 listener。
- 文案：删除/替换全部"在远控页打开一次…"（`app_zh.arb` 263–319 行区间内相关键 + `mcp_servers_page.dart:82` 的误用）；统一为"正在从本机读取/本机返回空列表/本机没有提供此能力/连接失败，点击重试/上次同步 …"。
- Settings 页进入即读 native 连接诊断/通知模式/截图策略/生物识别/电池/主题/locale/能力摘要；写开关等回执，失败回滚。

测试：进入 usage/model/plugin/MCP 页立即触发 repository load（不打开 WebView）；coordinator 未 ready 注册 intent、ready 后执行一次；F14（method not found→unsupported，不引导网页）；多设备 fixture 下工作台数据不混设备（F16 前置）。
**Gate G5**：`rg -n "远控页" lib/` 仅剩 WebView 兼容设备分支。
**Commit**：`feat: make workbench and settings data native-first and auto-loading`

---

### S6（05:45–06:35）UI/IA + 后台/通知/隐私策略

- 主题 tokens 收口：background/surface/field、textHigh/Medium/Low、accent/live/warning/danger、border/hairline、spacing 4/8/12/16/24/32、radius 8/12/16、字号梯度；所有页面颜色只走 `context.zt.*`（延续现有设计约定：细分隔线+留白、单一强调色、无 emoji）。
- Shell 视觉：标题≤两行；draft 空态最小化；思考/工具/权限块折叠但状态明显；错误局部 banner 不占正文；composer 贴底兼容键盘 inset；44–48dp 触控目标。
- P1-USAGE-011 修复：`agent_usage_page.dart` 安全过滤改为**显式 allowlist**（以 S0 第 6 项 fixture 的字段清单为准）：只放行数值/布尔指标 + 明确键表；删除"key 含 session 即指标"和"≤80 字符 String 放行"两条模糊规则。
- 通知两模式（P1-NOTIFY-014）：安静模式（默认，无常驻 FGS，回前台 bootstrap/reconcile）；持续连接模式（用户显式开启，合规低重要性前台通知）；事件 channel 与 FGS channel 分离、默认不 heads-up；事件去重与 resolved 撤回保留现有逻辑。
- 截图策略（P1-PRIVACY-013）：**不预设 FLAG_SECURE**（源码已证无）。代码侧做三件事：启动时记录 window flags 诊断日志；加 instrumentation 断言 `FLAG_SECURE` 未被置位；敏感值（链接/token/sessionId）redaction 检查。真机复现列入阶段 8 手工清单。
- 日志红线：仅 device alias/epoch/service/method/duration/safe code；禁打 args/response 全量。

**Gate G6**：`rg -n "FLAG_SECURE|setSecure" android lib` 零命中（或仅有诊断用途且有注释）；`rg -n "session.*contains|_isSafeScalar" lib/ui/agent_usage_page.dart` 确认模糊规则已删。
**Commit**：`fix: make background, notification, screenshot and logging policies explicit`

---

### S7（06:35–08:10）Fake Relay + 全量自动化（95 分钟）

目录：
```
test/fixtures/native/verified/*.json + 同名 .md   # S0 产出
test/fixtures/native/legacy/*.json                # 历史形状
test/fake_relay/fake_relay_server.dart            # dart:io WebSocket，脚本驱动
test/fake_relay/failure_script.dart               # F01–F16
```

故障注入表（在原 F01–F14 上新增两项）：

| 编号 | 注入 | 预期 |
|---|---|---|
| F01–F14 | （沿用自测方案原表） | 原预期 |
| **F15** | bridge 重建（epoch+1）后旧 stream 推送 + 新 stream 推送交错 | 旧 epoch 行丢弃；新 bridge 实时行 2s 内出现在时间线；无重复 |
| **F16** | 两台设备各自 workbench 数据 + 切换设备 | 工作台仅显示当前设备数据；无跨设备字段混合 |

测试文件（对应新建）：`native_bootstrap_state_test / response_router_test / runtime_config_repository_test / conversation_identity_test / conversation_reducer_test / workspace_grouping_test / notification_policy_test / screenshot_policy_test / composer_action_test / native_shell_test / workbench_autoload_test / capability_manifest_test / security_redaction_test`；`integration_test/native_conversation_flow_test.dart`（14 步全流程：bootstrap→draft→create→send→thinking/tool/assistant→展开→切模型成功/切思考 rejected→usage/plugin/MCP 自动加载→双击 stop→断线重连→退出恢复）；golden ≥12 张（draft_connecting / draft_ready / existing_history / thinking_expanded / tools_grouped / model_sheet / thought_sheet / context_sheet / running_composer / workbench_error / workbench_stale / settings_native）。

golden 纪律：固定 viewport/字体/locale/主题/时间；golden 变更必须在进度记录里写一句原因，禁止 `--update-goldens` 掩盖回归。

**Gate G7**：`flutter analyze` 0 issues；新增测试全绿；基线无新增失败（BASELINE-FAIL 项单独列出）。任何失败：回滚到最近通过 checkpoint 修复重跑，不以时间为由带病进入 S8。
**Commit**：`test: add native conversation contract fixtures and failure-injection coverage`

---

### S8（08:10–09:00）验证 / 构建 / 签名 / 扫描 / 交接

```bash
# 1) 静态与测试（env 模板，见 §A.1）
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze && flutter test

# 2) release 构建（签名材料只在本地，绝不入库）
cp <SECRETS_DIR>/... → android/key.properties   # 按现有 provision 脚本约定，构建后删除
flutter build apk --release

# 3) 签名完整验证（apksigner 在 build-tools/36.0.0）
apksigner verify --verbose --print-certs app-release.apk

# 4) secrets 扫描（必须零命中真实凭据）
rg -n -i 'remote/v4\?sid=|passHash=[A-Za-z0-9+/=]{16,}|keyPassword=|storePassword=' .
rg -n -i 'wxid_|xwechat_files' .

# 5) 产物 SHA-256 + 打包交接 ZIP（用修复后的脚本；ui-reference 只保留真实 WorkBuddy 材料，ZREMOTE 截图移回 docs/）
```
- 签名失败/材料不可用 → 交付 debug-signed 并**明确标注**，不得用临时新 keystore 冒充正式签名。
- 交接报告（`docs/PROGRESS-9H.md` 最终摘要 + Desktop ZIP 内 HANDOFF-REPORT）三类严格分列：**自动化通过 / 真机未执行（含：截图根因复现、Relay 真机握手、后台恢复、生物识别、MIUI 电池）/ 协议未验证项**。
- 重写 HANDOFF.md 的"✅"表：以本轮测试输出与截图为准（P1-DOCS-012）。
- 最终 commit：`chore: package nine-hour native iteration handoff`

**Gate G8**：APK+ZIP 落 Desktop 且有 SHA-256；三类状态分列；"构建成功"未写成"真机验收完成"。

---

## 四、全程规则（继承第二轮审计第四节，逐条有效）

1. 不使用 `git reset --hard`/`checkout --` 清理用户文件；每阶段 commit 即 checkpoint，可回滚。
2. 协议字段以 app.asar 证据 + fixture 为准；拿不到证据 = NOT-VERIFIED = 只读 + unsupported/notReturned 显示，绝不猜、绝不伪造成功态。
3. sid/hash/token/keystore/完整远控 URL/真实设备名/绝对用户目录：不读取原文、不输出、不入库、不进 ZIP；每次打包前跑 §S8 第 4 步扫描。
4. WorkBuddy 材料仅本地 UI/IA 参考；`workbuddy.apk`/`wb_libapp.so`/`wb_icons.txt` 不进 Git、不进 Flutter assets、不进 release artifact。
5. 不做静默自动批准；一切写操作用户显式触发（stop 例外——用户已预授权）。
6. 不调用 `coding-plan-subscription` 等 30+ 账户计费接口（COMPLIANCE 红线）。
7. 真机/ADB 只在目标设备真实出现时执行；不存在则最终报告如实写"未执行"，不模拟。
8. 中文路径/参数：写临时文件执行，不用 heredoc 传中文（历史踩坑）。
9. 探针/响应归属判断以"返回内容形状"为准，不信顺序（off-by-one 历史踩坑，S1 路由器根治后仍作为排障原则）。

## 五、完成定义（九小时结束时必须全部成立）

1. 首屏只有统一原生 ConversationShell；draft 不是独立页面。
2. Transport/Agent/Workspace/SessionSubscription 四层状态可区分；"可发送"只由真实 readiness（含订阅 ack）推导。
3. create/send/stop 有明确回执或可恢复策略（clientOperationId + task index 恢复），不靠固定延时。
4. push/pull/receipt/reconnect/optimistic 全部经过同一 reducer；无 ID 消息有低置信度 canonical key，S05 场景重放零重复。
5. Relay 重连（epoch 变化）后 conversation stream 自动绑定新 bridge，实时推送恢复 ≤2s。
6. 模型/思考/上下文零硬编码假能力（`max` 这类真值能显示）；写操作基于 S0 验证的协议，否则只读。
7. 工作台/设置不依赖"先打开远控页"；数据严格按 device+workspace 隔离，无跨设备混合。
8. stop 无二次确认、双击只发一次；send/stop 共享单一 primary slot。
9. usage/日志/通知不泄露 sessionId/token/path 等敏感字段（显式 allowlist）。
10. analyze/test/integration 结果真实记录；release APK 有 SHA-256 + apksigner 完整验证输出。
11. 真机未测项、app.asar 未验证项、iOS 未构建项在交接报告中如实单列。

---

## 附录 A.1 Flutter 命令环境模板（Git Bash 必用，照抄）

```bash
export PUB_CACHE="<TOOLS_ROOT>/pub-cache"
export NO_PROXY=localhost,127.0.0.1,::1
F="<TOOLS_ROOT>/flutter/bin/flutter"
D="<TOOLS_ROOT>/flutter/bin/dart"
export JAVA_HOME="<TOOLS_ROOT>\\jdk-17"
export ANDROID_SDK_ROOT="<TOOLS_ROOT>\\android-sdk"
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export GRADLE_USER_HOME="<TOOLS_ROOT>\\gradle"

env "PROGRAMFILES(X86)=C:\\Program Files (x86)" "PROGRAMFILES=C:\\Program Files" \
    "SystemRoot=C:\\Windows" "windir=C:\\Windows" "ComSpec=C:\\Windows\\System32\\cmd.exe" \
    "$F" test    # analyze / build apk --release 同理
```

## 附录 A.2 Commit 序列（9 个，一一对应阶段）

```
chore: import nine-hour iteration planning docs          # S0 前置
chore: freeze native iteration baseline and protocol evidence
feat: add single native bootstrap coordinator and readiness state
feat: unify draft and existing sessions in native conversation shell
fix: unify conversation reducer and single-slot composer actions
feat: centralize verified runtime config discovery and updates
feat: make workbench and settings data native-first and auto-loading
style: rebuild native shell and workbench information hierarchy   # 并入 S6 commit 亦可
fix: make background, notification, screenshot and logging policies explicit
test: add native conversation contract fixtures and failure-injection coverage
chore: package nine-hour native iteration handoff
```

## 附录 A.3 真机待办清单（用户重新授权后执行，本轮不做）

- ADB/无线调试连接指定设备；Relay 真机握手 + create/send/reply/stop 全链路
- 截图限制复现（重点：local_auth 弹窗期间、MIUI 系统策略），定位后回填 P1-PRIVACY-013
- 切后台恢复、MIUI 电池优化/自启动白名单
- 安静模式无常驻通知、持续模式通知合规
- 系统字体 200%、TalkBack、旋转
- 锁屏通知脱敏
- 验收时**不得**打开同一 sid/hash 的网页远控页，否则 native 证据作废
