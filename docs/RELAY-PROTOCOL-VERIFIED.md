# relay 协议实测记录（已跑通）

> 本文与 [NATIVE-CLIENT-FEASIBILITY.md](NATIVE-CLIENT-FEASIBILITY.md) 的关系：
> 那篇是**静态分析推断**，本文是**真实连接验证**的结果。两者冲突时以本文为准
> ——静态分析里推断错的点已在文末「被推翻的推断」中列明。
>
> 验证方式：用真实二维码链接连接 `wss://zcode.z.ai/ws`，完成握手、取工作区、
> 打开工作区桥、收帧并回执。全程只读，未发送任何写操作。

## 一、链接参数（实测）

ZCode 3.11.2 生成的链接：

```
https://zcode.z.ai/remote/v4
  ?sid=<deviceSid>
  &hash=<passHash，URL 编码的标准 base64>
  &t=<毫秒时间戳>
  &mid=<deviceMid，UUID>
  &name=<主机名>
  &app_version=3.11.2
```

要点：

- **没有 `relayOrigin`**，中继地址取链接自身 origin（`https://zcode.z.ai`）
- `hash` 需 URL 解码后作为 HMAC 密钥的原始 UTF-8 字节；它是标准 base64（含 `+` `/` `=`），
  不是 URL-safe base64
- 路径是 `/remote/v4`（不带尾斜杠）
- `app_version` 决定 v4/v3：主版本 > 3，或 3.x 且 x ≥ 4 走 v4

## 二、连接与握手（实测报文）

### 2.1 建连

```
WS  wss://zcode.z.ai/ws?mid=<deviceMid>
```

**不带** `X-Device-ID` 头——那是桌面端（role=`device`）才用的；手机端（role=`terminal`）
只用 `?mid=`。

### 2.2 握手三步

上行（平铺，**不套 data 外壳**）：

```json
{"type":"auth_init","role":"terminal","device_sid":"<sid>",
 "meta":{"platform":"android","version":"3.11.2","name":"mobileApp"},
 "client_ts":1789014602337}
```

服务端下行（**字段平铺在顶层，不在 `payload` 里**）：

```json
{"type":"auth_challenge","server_ts":1789014602,"nonce":"<nonce>"}
```

上行：

```json
{"type":"auth_response","device_sid":"<sid>","proof":"<proof>","client_ts":…}
```

服务端下行：

```json
{"type":"auth_ack","server_ts":…,"device_sid":"<sid>",
 "terminal_sid":"t_<example>","pair_status":"matched"}
```

- `proof = base64url_nopad(HMAC-SHA256(key=passHash, msg="{nonce}|terminal|{deviceSid}"))`
  ——**已由服务端接受，算法确认无误**
- 握手后服务端会发 `pair_status_ack`：`{"type":"pair_status_ack","pair_status":"matched","terminal_sid":""}`
- 心跳：`{"type":"pair_status_query","device_sid":"<sid>","client_ts":…}`

## 三、上行数据必须套 `data` 外壳（关键）

官方 `payloadSerializer.prepare` 的实现等价于：

```js
const message = { type: 'data', payload: <payload>, client_ts: Date.now() };
if (byteLength(JSON.stringify(message)) > 1024 * 1024) → oversize，拒发
```

即所有 `zcode_type` 负载都要包成：

```json
{"type":"data","payload":{"zcode_type":"workspace-list-request","requestId":"…"},"client_ts":…}
```

**踩过的坑**：直接发裸负载会被中继以
`{"type":"error","code":"WRONG_PARAM"}` 拒绝。

## 四、取工作区列表（实测响应形状）

上行：

```json
{"type":"data","payload":{"zcode_type":"workspace-list-request","requestId":"…"},"client_ts":…}
```

下行：

```json
{"type":"data","server_ts":…,"payload":{"requestId":"…","result":{
  "activeTaskId":"sess_…",
  "activeWorkspaceKey":"D:\\<workspace>",
  "tasks":[
    {"taskId":"sess_…","title":"…","displayStatus":"running","provider":"glm",
     "workspaceKind":"local","workspaceLabel":"工作1",
     "workspacePath":"D:\\<workspace>","createdAt":…,"updatedAt":…}
  ]
}}}
```

**注意**：`result` 里**没有 `workspaces` 数组**。工作区必须从 `tasks[].workspacePath`
（回退 `workspaceKey`）归并去重得到；当前打开的工作区由顶层 `activeWorkspaceKey` 给出。

远控只允许访问桌面端当前打开的那个工作区，所以 **`activeWorkspaceKey` 是权威来源**。

`tasks[].displayStatus` 取值实测有 `running` / `completed`，与现有
`session_index` 的 phase 语义一致，可直接复用。

## 五、打开工作区桥

上行：

```json
{"type":"data","payload":{
  "zcode_type":"workspace-bridge-open",
  "requestId":"…","bridgeSessionId":"…","bridgeGeneration":1,
  "workspaceKey":"D:\\<workspace>"}, "client_ts":…}
```

下行：

```json
{"type":"data","payload":{
  "zcode_type":"workspace-bridge-ready",
  "requestId":"…","bridgeSessionId":"…","bridgeGeneration":1,
  "bridge":{"bridgeSessionId":"…","bridgeGeneration":1,
            "initialTaskId":"sess_…","kind":"local",
            "workspaceKey":"D:\\<workspace>","workspacePath":"D:\\<workspace>"}
}}
```

- **`bridgeSessionId` 用我们自己生成的 id 是被接受的**（官方页面也是自己生成）
- 匹配谓词按 `bridgeSessionId`，**不是** `requestId`（虽然本次实测 `requestId` 也回了）
- `bridgeGeneration` 从 1 开始，每次重开桥递增

## 六、数据帧与回执

下行帧：

```json
{"type":"data","payload":{
  "zcode_type":"rpc-frame",
  "bridgeSessionId":"…","bridgeGeneration":1,
  "checksum":{"algorithm":"crc32","value":"b4ff6360"},
  "dataBase64":"BAEGyAEA",
  "fragmentCount":1,"fragmentIndex":0,
  "messageBytes":6,"messageSeq":1,"seq":1
}}
```

### 6.1 CRC32 已对齐

`crc32(0x04 0x01 0x06 0xC8 0x01 0x00)` = `b4ff6360`，与帧内 `checksum.value` 完全一致。
我们用标准 IEEE CRC-32（多项式 `0xEDB88320`）实现，可直接用于校验。

### 6.2 必须回 ack，否则会被反复重传

回执形状：

```json
{"type":"data","payload":{
  "zcode_type":"rpc-frame-ack",
  "bridgeSessionId":"…","bridgeGeneration":1,
  "ackMessageSeq":1}, "client_ts":…}
```

**实测对比**：不回 ack 时，同一 `messageSeq` 的帧被重复推送（每次 bridge 重建后重发一次）；
补上回执后只推一次、不再重传。所以 ack 不是可选项。

### 6.3 载荷是**二进制**，不是 JSON

`dataBase64 = "BAEGyAEA"` 解出来是 `04 01 06 C8 01 00`，按 varint 解为 `[4, 1, 6, 200, 0]`。
**不是 JSON 文本。**

这是与 WebView 路径最大的差异，也是**下一步要啃的最后一层**：

- 现有 WebView 钩子之所以能拿到 JSON，是因为它抓的是页面自己解码后的中间产物；
  原生直连拿到的是这个二进制层
- 所以「现有 `SessionStateExtractor` 直接复用」这个设想**在当前帧上不成立**
  ——需要先把这个二进制格式解出来

## 七、当前实现状态

已完成并验证（`lib/relay/`）：

| 模块 | 内容 | 验证 |
|---|---|---|
| `relay_proof.dart` | HMAC-SHA256 + base64url 无填充 | 服务端接受 ✓；Python 交叉向量 ✓ |
| `relay_link.dart` | 链接解析（含实测链接固定用例） | 单测 ✓ |
| `relay_frame.dart` | 信封 / 握手消息 / rpc-frame 解析、WireBase64、CRC32 | 单测 ✓；CRC 对真实帧 ✓ |
| `rpc_assembler.dart` | 分片重组、缺口检测、上限保护、超时清理、重传去重 | 单测 ✓ |
| `relay_socket.dart` | WS 抽象 + `dart:io` 实现（可注入 HttpClient 走代理） | 真机联通 ✓ |
| `relay_channel.dart` | 握手、心跳、RPC 配对、**自动回 ack** | 真实 relay ✓ |
| `relay_bridge.dart` | 引导编排：列工作区 → 开桥 → 帧重组 → **任务快照** | 真实 relay ✓ |
| `state/relay_source.dart` | 每设备一条通道，任务快照写入 `session_index` | 单测 ✓ |

**任务列表数据层已完全打通**：`workspace-list-response.result.tasks[]` 与 WebView 侧
`TaskIndexExtractor` 认识的形状**完全一致**，因此直接复用同一个提取器——
真机实测解析出 33 条真实任务，`displayStatus` → `phase` 映射正确。

→ **结论：原生任务列表不需要等帧流。** 二进制帧只影响**会话正文与实时流**。

联调探针：`tools/relay_probe.dart`（本地调试用，凭证只从命令行/本地文件传入，
产物与凭证均在 gitignore 的 `tools/` 下，不入库）。

## 八、会话层（正文 / 工具调用）—— **已完全打通**

任务列表走的是桥的**非帧负载**，所以已经能用。正文与工具调用走的是**会话层**，
以下是已确认的协议形状（来自服务端页面 bundle 内的 zod schema）。

### 8.1 全部 `zcode_type` 词汇表（页面里共 9 个）

```
mobile-diagnostic
rpc-frame
rpc-frame-ack
platform-request
workspace-list-request
mobile-view-state-update
workspace-reconnect-request
workspace-bridge-open
bootstrap-request
```

**注意：没有 subscribe 类**。所以订阅不走独立的 `zcode_type`。

### 8.2 二进制 RPC 编码（**已完全逆向，逐字节验证**）

`rpc-frame.dataBase64` 里装的**不是 JSON**，而是二进制 agentService RPC。
通过用真实浏览器打开链接、钩住 `WebSocket.prototype.send` 抓到官方页面 **117 帧上行**，
全部可解析；编码结果与官方帧**逐字节一致**（含 CRC 与 base64）。

帧结构：

```
04 04 06 <kind> 06 <varint seq> 01 <varint len> <service>
         01 <varint len> <method> <args>
```

- `kind`：`0x64`('d') = 方法调用；`0x66`('f') = 事件订阅/回调注册
- `service`/`method`：UTF-8，varint 长度前缀
- `args`：
  - 'd'：`04 <varint 个数>` 后跟若干「带类型标签的值」
  - 'f'：单个值，或 `00` 表示无参
- 值标签：`0x01` = 字符串，`0x05` = JSON

**编码三处硬约束（都踩过）**

1. `dataBase64` 必须是**标准 base64 且带填充**。实测官方 117 帧：86 帧含 `=`、
   4 帧含 `+/`、**0 帧含 `-_`**。用 URL-safe 无填充会被判定 `rpc-transport-fault`。
2. **解码要同时接受两种字母表**。桌面端下行的 `dataBase64` 就是标准 base64；
   只认 URL-safe 会把 1000+ 字节的正文帧整条丢掉（早期踩过）。
3. JSON 参数要传 **Map/List，不要自己 `jsonEncode`**，否则会被打成字符串标签。

`checksum.value` 是标准 IEEE CRC-32（`crc32(04 01 06 c8 01 00) = b4ff6360` 已验证）。

### 8.3 会话相关的服务方法（实测抓包）

服务名 `zcode-agent`：

```
subscribeSessionsIndexV4   {workspacePath, runtimePolicy:'existing-only'}
subscribeConversationV4    {workspacePath, sessionId}
conversationRowsRangeV4    {workspacePath, sessionId, beforeRowId?, limit:200}   ← 正文行
conversationPlansV4        {workspacePath, sessionId}
helloConversationV4        （无参）
initializeConversationV4   {kind:'clientHello', protocolVersion:3, clientId,
                            clientKind, appVersion, capabilities}
```

其他实测服务：`window-controller`（`subscribeControllerV4`，topic 形如
`controller/workspaces`、`controller/tasks-index`）、`broadcast`、`setting`、
`file-watcher`、`model-provider`、`oauth`、`zcode-task`、`git`、`zcode-session`、
`coding-plan-subscription`。

> ⚠️ `helloConversationV4` / `initializeConversationV4` **走二进制 agent RPC**，
> **不是** `platform-request`。早先按 `platform-request` 发会超时收不到响应——
> 这就是当时"唯一卡点"的真实原因。

### 8.4 响应帧格式（与请求不同！）

**已打通。** 响应头部和请求**不一样**，这是当时解不出来的原因：

```
请求 04 04 06 <kind>  06 <varint seq> 01 <len> <service> 01 <len> <method> <args>
响应 04 02 06 <type> 01 06 <varint seq> 05 <varint len> <json>
```

- 第二字节：请求 `04`，响应 `02`
- `type`：`0xC9`(201) = 成功；`0xCA`(202) = 失败（体形如
  `{"message":"fault.…","name":"Error","stack":[…]}`）
- 响应体是**纯 JSON**（不再是二进制编码的值）
- ⚠️ 响应的 `seq` 是**桌面端自己的计数器**，不回显我们的请求序号 ——
  按 seq 配对不可靠，**按内容匹配**（如 `kind == 'hello'`）才稳

### 8.4.1 打通需要的四个修正

按重要性排序，每一个都是**实测验证过**的：

1. **`clientKind` 必须按 hello 的 `clientMode` 推导**。
   官方页面逻辑：`clientMode === 'desktop-continuous' ? 'desktop' : 'web'`。
   实测 `clientMode` 是 `web-remote-replayable` → 必须发 `'web'`。
   早先硬编码 `'mobileApp'`（枚举里合法）直接导致 `rpc-transport-fault`。
2. **订阅载荷要带 `connectionId` + `clientMode`**（来自 hello 响应）。
3. **响应解码**按 8.4 的头部（第二字节 `02`）。
4. **请求头/响应头不能混解**：`04 04` 是请求、`04 02` 是响应。

### 8.4.2 打通后的实测结果

```
会话层握手 ok=true  clientMode=web-remote-replayable
capabilities={"nativeDialogs":false,"localTerminal":false,
              "binaryFrames":false,"compression":"none","workspaceHookReview":true}

[rows] 30 条  {toolCall: 13, reasoning: 4, assistantText: 3, hookInvocation: 10}

toolCall      #613  Bash  success  {"command":"node engine/tests/test-… 2>&1 | tail -14"}
reasoning     #614                Three test bugs (not product bugs):
assistantText #615                三处均为测试脚本自身问题（revision 算术…）。修正。
toolCall      #616  Edit  success  {"replace_all":false,"file_path":"…test-r4-approval.js"}
```

**正文、思考过程、工具调用（含工具名/状态/入参）、钩子调用 —— 全部原生拿到，
完全不需要 WebView。** 且不再出现 `bridge-degraded`。

### 8.4.3 行（row）的字段

`conversationRowsRangeV4` 响应为 `{"rows":[…]}`。

#### 真机抽样（200 行）实测分布

```
原始 kind              映射后              说明
   7  turnHeader         7  turnHeader      ✅
  41  reasoning         41  reasoning       ✅
  38  assistantText     38  assistantText   ✅
 108  toolCall         108  toolCall        ✅
   3  userInput          3  userText        ✅ 注意上游叫 userInput
   3  timelineMarker     3  （标记块）       模型切换标记
```

真机上出现过的工具名：`Bash, Edit, Read, TaskOutput, TodoWrite, Write`。

#### 各类型的真实字段

`assistantText`
```json
{"kind":"assistantText","text":"…","state":"complete"}
```

`reasoning`
```json
{"kind":"reasoning","text":"…"}
```

`toolCall`
```json
{"kind":"toolCall","toolName":"Edit","status":"success",
 "toolCallId":"call_…","inputText":"{…}"}
```

`userInput` —— ⚠️ **真实用户消息的 kind 是 `userInput`，不是 `userText`**
```json
{"kind":"userInput","text":"继续","origin":"realUser",
 "sourceCommandId":"…","rootSourceCommandId":"…","clientId":"…"}
```
`origin` 实测取值：`realUser` / `backgroundResult` / `goalContinuation` /
`mailbox` / `synthetic`。
**只有 `realUser` 才是真人发言** —— 后台结果也走这个 kind，
UI 上不该长得一样，否则会误导来源。

`turnHeader`
```json
{"kind":"turnHeader","origin":"backgroundResult","executionKind":"agent",
 "historyRoundCount":38,"state":"completedSuccess",
 "startedAt":…,"endedAt":…,"activeMs":2041220,
 "originMeta":{"backgroundSource":"bash","workId":"exec_…",
               "title":"Final full regression for R3 evidence"}}
```
- `origin`：`userInput` / `backgroundResult` / `goalContinuation` / `editRerun`
- `originMeta.title` 是**人类可读的轮次标题**，值得展示
- `activeMs` 是实际耗时
- ⚠️ **`fileChanges` 是可选的**，实测这一条就没有 —— 不要假设它一定在

`timelineMarker` —— 实测用于**切换模型**
```json
{"kind":"timelineMarker","lane":"lightBoundary",
 "marker":{"type":"modelChange",
           "fromProvider":"…","fromModel":"deepseek-v4-flash",
           "toProvider":"…","toModel":"mimo-v2.5","toThought":"enabled"}}
```

`hookInvocation`
```json
{"kind":"hookInvocation","hookInvocationId":"…",
 "hookEventName":"SessionStart|UserPromptSubmit|PreToolUse|PermissionRequest|PostToolUse|PostToolUseFailure|Stop",
 "hookCount":1,"state":"running|completed|failed",
 "lane":"assistantWork|toolBefore|toolAfter","anchorToolCallId":"…",
 "executions":[{"hookRunId":"…","didExecute":true,"state":"…","outcome":"…",
                "displayName":"…","sourceKind":"user|plugin|project"}]}
```

`permission` —— 待批准（见 8.8）
```json
{"kind":"permission","toolCallId":"…","toolName":"Bash","summary":"…",
 "options":[{"optionId":"…","label":"…",
             "kind":"allowOnce|allowAlways|deny|custom"}]}
```

#### 行类型全集（官方 union 里的全部）

```
userInput  assistantText  reasoning  toolCall  hookInvocation  permission
turnHeader  timelineMarker  local  remote  subagent  synthetic
workspaceHookReview  cua  memory  scheduled  compact  image  video  audio  pdf  file
progress  result  error  started  ssh  wsl  docker  server
```

公共字段：`rowId`（**分页游标**）、`turnId`、`entityId`、`productTurnId`、
`visibility`、`createdAt`、`createdAtSeq`。

翻页：请求带 `beforeRowId`（取当前最旧一行），`limit` 官方用 200。

⚠️ **调用顺序**：实测**先 `subscribeConversationV4` 再 `conversationRowsRangeV4`**；
顺序反了会拉不到（超时）。

### 8.5 线框层（与二进制 RPC 并存的一层）

`helloConversationV4` 的响应 schema 形如：

```js
{ wireVersion: 3,
  kind: 'complete' | 'fragment',
  deliveryKind?: 'initial' | 'online' | 'recovery',
  logicalFrameId, logicalFrameOrdinal,
  topic,            // 'conversation/<sessionId>' 或 'sessions-index/<identity>'
  subscriptionId,
  // complete:
  frame?,
  // fragment:
  fragmentIndex, fragmentCount, logicalBytes, checksum, dataBase64 }
```

### 8.6 能力协商：`binaryFrames`

```js
capabilities = {
  nativeDialogs, localTerminal,
  binaryFrames,                              // ← 布尔，决定帧是不是二进制
  compression: 'none' | 'permessage-deflate',
  workspaceHookReview?
}
```

**这是关键**：页面调 `initializeConversationV4` 时**只声明
`capabilities:{workspaceHookReviewUi:true}`，不声明 `binaryFrames`**。
我们收到未协商的二进制控制帧（`04 01 06 c8 01 00`）正是因为**从没做过这步协商**。
所以"帧是二进制"不是固然的——**它是可协商的**。

### 8.7 订阅载荷

```js
// 请求
{ topic, base?: {logEpoch, seq}, visibility?: 'foreground'|'background',
  connectionId, clientMode: 'desktop-continuous'|'web-remote-replayable',
  workspace?, legacyTaskIds?, resumeThoughtLevel? }

// 响应
{ ack: { subscriptionId, mode: 'snapshot'|'resume', logEpoch } }

// 取消订阅
{ subscriptionId, base: {logEpoch, seq}|null, forceSnapshot? }
```

- topic：`conversation/<sessionId>`、`sessions-index/<workspaceIdentity>`
- `connectionId` / `clientMode` 来自 `hello` 的响应

### 8.8 命令层（原生会话已接入）

```js
{ commandId, clientId, sessionId: string|null,
  baseRevision?,        // CAS 命令必带（内部文档 10-protocol-spec §6.4）
  baseLogEpoch?,        // row target 命令必带
  type, payload, issuedAt }
```

命令类型全集：

```
applyFileRewind  forkAssistant  editUserQuery  retryTurn  setAssistantFeedback
sendQueuedNow  editQueueItem  reorderQueueItem  deleteQueueItem  setAutoDrain
switchModelConfig  switchCollaborationMode  setFollowupMode  pauseGoal  resumeGoal
snoozeInteractionAutoResolution  …（另有 resolveInteraction / sendText / createSession 等）
```

**其中 CAS 命令（`applyFileRewind`/`forkAssistant`/`editUserQuery`/`retryTurn`/
`setAssistantFeedback`）必须带 `baseRevision`**，否则被拒。

### 8.9 服务对象从哪来

页面里 `helloConversationV4` 挂在 **`agentService`** 上，而 `agentService` 由
Electron 主进程/preload 注入（web remote 模式下是 `Y9({webRemoteControlProxy})`
造的代理）。所以它**不是**普通的 `platform-request` 方法——这一点解释了 8.2 的超时。

当前实现已确认 web remote 模式下的 Agent service 通过 `rpc-frame` 内的二进制
`agentService` RPC 传输；`RelayBridge.callService()` 统一负责编码，设置面板和会话
命令共用同一条安全的单飞请求队列。

## 九、下一步

### 已完成
- 原生通道：握手 / 取工作区 / 开桥 / 收帧 / 回执 / 任务快照 → `session_index`
- UI 接入：支持 Relay 的设备走 `NativeDeviceView`，不再与 WebView 并行占用同一凭证
- **二进制 RPC 编解码**（`lib/relay/agent_rpc.dart`）：与官方帧逐字节一致，
  16 个单测，其中 4 个用真实抓包样本做基准
- 会话 API 已封装：`subscribeConversation` / `conversationRows` /
  `conversationPlans` / `subscribeSessionsIndex`（`RelayBridge`）
- 原生会话页：新对话入口、历史分页、按工作区归类、实时更新合并、工具/思考/待办/授权、
  模型/思考级别/上下文控制、附件发送与停止执行
- 命令层：`createSession` / `resolveInteraction` / `sendText` / `switchModelConfig` /
  `stop` 由用户明确点击触发，并按回执判定结果
- Agent 面板：skills / MCP / plugins / commands / subagents / hooks / memory /
  usage / indexing 的原生路由；未核验写接口保持只读
- 复用真实浏览器抓包的方法已固化（见第十一节）

### 剩余（按依赖排序）
1. 真机最终验收：Relay 断线恢复、后台恢复、生物识别与授权写操作（当前按用户要求暂停）
2. iOS release 构建验证（需要 macOS/Xcode）
3. 对后续新增的官方写接口逐个确认 schema、权限和幂等性后再接入

## 十、复现抓包的方法（已跑通）

用内置浏览器驱动脚本 + 页面内挂钩，抓官方页面的真实上行：

```bash
# 1) 打开链接（agent-browser 自带 Chromium）
agent-browser open "<remote/v4 链接>"

# 2) 注入原型级挂钩（必须在页面建连后也能拦到）
agent-browser eval "$(cat tools/ws_hook_proto.js)"

# 3) 在页面上点进一个会话触发订阅，然后导出
agent-browser eval "$(cat tools/dump_hex.js)"
```

**踩坑记录**

- 构造器级挂钩（包装 `window.WebSocket`）**拦不到已建立的连接**；
  必须改挂 `WebSocket.prototype.send` / `addEventListener`
- `--init-script` 只在浏览器**首次启动**时注册；复用一个已存在的 daemon 会静默失效
- 抓到的帧存 `tools/captured_frames.json`（含 hex），已 gitignore

## 十一、被推翻的推断

静态分析那版里以下结论是**错的**，以本文为准：

| 曾经的推断 | 实测事实 |
|---|---|
| 二维码链接参数是 `remoteControlToken` + `relayOrigin` | 实际是 `sid` / `hash` / `t` / `mid` / `name` / `app_version` |
| 手机端要走 4 个 REST + 2 条 WS | QR 流程**完全不用 REST**，单条 WS 即可 |
| 握手字段嵌在 `payload` 里 | 实测**平铺在顶层** |
| `workspace-list-response` 返回 `workspaces[]` | 没有该字段，需从 `tasks[]` 归并；`activeWorkspaceKey` 才是权威 |
| `workspace-bridge-ready` 按 `requestId` 匹配 | 官方谓词按 `bridgeSessionId` |
| 帧内容与 WebView 抓到的同形，解析器可复用 | **对任务列表成立**（已验证）；会话正文待确认 |
| ack 可选 | 不回 ack 会被反复重传，**必须回** |
| 「帧是二进制 → 做不了原生 UI」 | **错**。任务列表已原生打通；二进制只影响会话正文 |
| 「会话服务走 `platform-request`」 | **错**。走的是**二进制 agentService RPC**；按 platform-request 发会超时 |
| 「`dataBase64` 是 URL-safe base64」 | **错**。是**标准 base64 带填充**（117 帧中 86 帧含 `=`、0 帧含 `-_`） |

> 另注：官方 zod schema 里客户端类型枚举含 `mobileApp`，即原生 App 属于被预期的形态。
