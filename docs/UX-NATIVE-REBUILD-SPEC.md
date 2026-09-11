# ZCode Control 原生会话与工作台重构规格

这是下一轮实现的“行为合同”。设计、状态层、RPC 层和测试都以此为准。所有文字可以继续本地化，但状态语义不能改变。

## 1. 产品原则

### 1.1 一个入口，一个会话壳

支持 Relay 的设备进入后永远渲染 ConversationShell。新会话不是一个独立页面，而是该 shell 的 draft 状态：

~~~text
AppShell
  └─ DeviceConversationShell(device)
       ├─ Drawer: device → workspace → session
       ├─ Header: session title / workspace / connection status
       ├─ Timeline: rows + thinking + tools + approvals
       └─ Composer: model / thought / context + one primary action slot
~~~

不存在“NativeDeviceView → NewConversationPage → ConversationPage”的嵌套跳转。允许保留 NewConversationPage 文件作为过渡，但它不能再成为原生设备的根路由；最终应删除或改成 shell 的 draft 子组件。

### 1.2 数据来源优先级

~~~
本机 ZCode v4 Relay
  → Agent service handshake
  → 能力清单与工作区 bootstrap
  → session index / conversation stream / runtime config / workbench
  → Riverpod repositories
  → 原生 Flutter UI
~~~

原生设备的默认路径不得打开官方远控网页，不得把 WebView 作为“获取模型/统计/插件”的前置动作。旧版本或无 Relay 凭据的设备可以保留明确的兼容入口，但不允许和同一 sid/hash 同时保持两条活动通道。

### 1.3 权威数据与不确定数据分开

所有页面必须区分：

- loading：请求尚未完成。
- fresh：本次连接得到的权威数据。
- stale：有上次缓存，但已超过 freshness window。
- empty：权威返回空列表。
- unsupported：服务明确表示不支持。
- notReturned：连接存在，但该调用没有返回需要的字段。
- transportError：连接或 RPC 失败，可重试。
- writeRejected：写操作被桌面端拒绝，保留旧值。

“没有数据”不能用默认模型、默认思考级别、任意 quota 数字或远控页面占位文案代替。

## 2. 启动与连接状态机

### 2.1 Coordinator

新增一个按 deviceId 唯一的 NativeBootstrapCoordinator，负责 orchestration，不让每个页面自己猜测连接时机。建议目录：

~~~
lib/native/bootstrap/
  native_bootstrap_coordinator.dart
  native_bootstrap_state.dart
  native_capability_manifest.dart
  native_request_receipt.dart
lib/repositories/
  connection_repository.dart
  workspace_repository.dart
  conversation_repository.dart
  runtime_config_repository.dart
  workbench_repository.dart
  settings_repository.dart
~~~

如果项目不希望新增 repositories 目录，可以放在 lib/state 下，但每个职责仍要独立，不能继续把所有 native service 访问聚集在 relay_source.dart。

### 2.2 状态枚举

Transport：

~~~
idle → connecting → relayReady → failed → retrying
~~~

Agent：

~~~
notStarted → handshaking → ready(capabilities) → unavailable(reason)
~~~

Workspace：

~~~
unknown → loading → ready(index, defaultWorkspace) → empty → error
~~~

Conversation shell：

~~~
connecting
draft(workspace?)
loadingSession
readyIdle
readyRunning
waitingApproval
reconnecting
fatal
~~~

配置：

~~~
unknown → loading → ready(snapshot) → stale(snapshot) → unsupported → error
~~~

每一次连接重建都生成递增的 connectionEpoch。所有回调、流事件、请求回执都必须携带 epoch；过期 epoch 的结果只能丢弃，不能覆盖新状态。

### 2.3 启动顺序

1. 从安全存储读取 device credential，敏感字段只在内存中使用。
2. 建立单一 RelayBridge。
3. 完成协议握手、服务列表和客户端模式确认。
4. 拉取 capability manifest；记录每个方法的 read/write、参数版本和来源。
5. 拉取 workspace/task/session index。
6. 选定最近工作区；没有工作区时进入 draft 但仍保留输入能力。
7. 并行预热：模型目录、当前 runtime config、context usage、usage stats、skills、plugins、MCP、commands、subagents、hooks、memory、indexing。
8. 进入 shell；页面只订阅 coordinator/repository 状态，不直接发起第二套重复请求。
9. 如有 pending notification tap 或上次打开的 session，恢复到相同 workspace/session。

并行请求必须受单设备并发上限保护；应支持优先级：连接/会话 > runtime config > 当前页面 > 后台工作台数据。

## 3. 首页与抽屉

### 3.1 首屏

支持原生 Relay 的设备首屏必须包含：

- 顶部汉堡菜单。
- 当前会话标题；draft 时显示“新对话”但不显示独立欢迎页。
- 工作区名称和连接状态。
- 正文区域：已有会话显示历史；draft 显示小型 empty state 与可直接输入的 composer。
- composer 的模型、思考、上下文信息和输入框。
- 单一 primary action slot。

draft 不得占据一大段屏幕做品牌图标/居中文字。最小 empty state 只说明当前工作区和输入提示，把主要面积让给输入。

### 3.2 抽屉信息架构

抽屉按以下顺序渲染：

~~~
设备
  连接状态 / 最后同步 / 诊断入口
  工作区 A
    运行中 / 待授权
    最近会话
    已置顶
  工作区 B
  未归类
~~~

排序规则：

1. 同一设备下按 workspacePath 的规范化路径分组。
2. 工作区内 pinned 优先。
3. 其次是 running、waiting approval。
4. 最后按 updatedAt 降序。
5. updatedAt 缺失时用服务返回顺序加稳定的 sessionId tie-breaker，不能每次随机跳。

每个会话行至少展示标题、相对时间、状态 pill、工作区名（跨组搜索结果时）、未读标记。删除、归档、置顶必须有准确回执或明确标为本地操作，不能只改 UI 假装成功。

## 4. 对话时间线

### 4.1 行归并

所有来自以下来源的 row 必须经过同一个 ConversationReducer：

- initial range。
- older range。
- realtime stream。
- accepted/started/completed receipt。
- optimistic user row。
- refresh fallback。

Canonical identity 优先级：

1. 官方 rowId。
2. 官方 entityId。
3. toolCallId。
4. messageId/clientOperationId。
5. 低置信度的规范化组合 key，并在 debug 诊断中注明。

Reducer 规则：

- 同 key 更新字段，不追加第二行。
- assistant streaming 行按版本或内容增量更新。
- receipt 只改变发送状态，不单独生成可见气泡。
- refresh 返回空时不能清空已有实时行，除非服务明确返回删除/归档。
- 分页合并后再排序，不能先展示重复再异步去重。

### 4.2 视觉块

每个 assistant 轮次可以包含：

- 用户消息。
- 思考块：默认折叠，显示“思考”、持续时间、是否完成；展开显示经脱敏的内容。
- 技能/工具块：按调用组折叠，显示技能名、输入摘要、结果状态、耗时和工具数量。
- Agent 正文。
- 权限/确认块：显示动作、影响范围、批准/拒绝按钮和回执状态。
- 错误块：显示错误级别、重试/复制诊断，不遮挡整个时间线。

思考持续时间来自 start/end 或服务 elapsed；缺字段时显示“时间未返回”。技能数量来自真实 tool/skill rows；不能用网络请求数猜测。

## 5. Composer 行为合同

### 5.1 布局

竖屏建议：

~~~text
┌─────────────────────────────────────────┐
│ [模型] [思考级别] [上下文 used / max]     │
│ [附件 chips …]                           │
│ 输入消息…                           [主动作] │
└─────────────────────────────────────────┘
~~~

主动作槽位固定在输入行最右侧，同一时刻只渲染一种主动作：

| shell 状态 | 输入状态 | 主动作 | 是否允许发送 |
| --- | --- | --- | --- |
| draft/readyIdle | 空 | 加号或附件 | 否 |
| draft/readyIdle | 有文字或附件 | 发送箭头 | 是 |
| readyIdle | 正在准备发送 | spinner | 否 |
| readyRunning/waitingApproval | 任意 | 方形停止键 | 否，除非桌面端允许并行消息 |
| stopping | 任意 | spinner | 否 |
| reconnecting | 任意 | 重连/禁用态 | 否 |
| fatal/unsupported | 任意 | 修复连接 | 否 |

附件 paperclip 是 secondary control，可以打开文件选择器；它不能和 send/stop 同时作为第二个 primary action。

### 5.2 发送

发送流程必须是：

1. 检查 shell readiness、工作区、文本/附件。
2. 生成 clientOperationId。
3. 在 reducer 里放入 pending user row，标记 pending，不重复放第二行。
4. 发送严格验证过的 command。
5. 等待 accepted receipt；若超时，显示 pending/重试，不立即重复发送。
6. 接收 session row/stream；完成后替换 pending 状态。
7. 失败时保留草稿和附件，提供一次明确重试。

创建新会话时，create + first message 若是桌面端原子方法，必须保留原子方法；若不是，按 create receipt → subscribe → send 顺序执行，并通过 clientOperationId 恢复迟到回执。

### 5.3 停止

停止是用户已经授权的即时写操作：

- 点击不弹 dialog。
- 立刻禁用主动作并进入 stopping。
- 只发送一次 stop request；requestId/epoch 防止双击重复。
- 收到 stopped/completed/failed 事件后回到 idle 或 waiting。
- 失败只显示 snackbar/banner 和“重试停止”，不二次确认。

## 6. 模型、思考和上下文

### 6.1 数据来源

下一位执行 AI 必须先从本机 ZCode 安装包 app.asar 中确认真实方法和返回形状，再写 fixture。当前本机路径记录为：

~~~
<ZCODE_INSTALL>\resources\app.asar
~~~

该 app.asar、sid、hash、token 和完整远控 URL 不得复制进 Git 或交接包。

### 6.2 模型选择器

模型 chip 只能显示已验证 current model。点击后：

- loading：显示骨架。
- fresh catalog：按 provider 分组、显示模型名、当前标记、enabled/disabled 原因。
- empty：明确“桌面端返回空目录”。
- notReturned：明确“桌面端未返回目录”，提供重试和诊断入口。
- unsupported：明确版本不支持，不能引导打开网页。

选中模型时只提交必要字段；如果切换模型会改变可用思考级别，先完成 model receipt，再刷新 thought options，最后更新 UI。

### 6.3 思考级别

思考选项从 capability manifest 或 current model metadata 来；候选项包含 id、显示名、是否可用、限制说明。禁止在 UI 中固定写死 none/low/medium/high/xhigh 作为真实能力。

如果协议只返回当前值、没有目录，UI 可以展示当前值，但选择器必须显示“可选级别未返回”，不能允许用户点击不存在的项。

### 6.4 上下文

上下文 chip 只接受 contextUsedTokens/contextMaxTokens/autoCompactThresholdTokens 等有明确语义的字段。配额、账单 usage、消息数都不能冒充上下文窗口。

显示规则：

- used 和 max 都有：used / max tokens，并显示百分比。
- 只有 used：used / — tokens。
- 只有 max：— / max tokens。
- 都没有：上下文未返回。
- threshold 有：在详情 sheet 显示自动压缩阈值。

## 7. 工作台、Agent 能力和设置

### 7.1 页面自动加载

每个页面的进入动作必须调用 repository 的 load(context, refreshIntent)：

- 先读取内存/磁盘缓存。
- 立即渲染 skeleton 或 stale 数据。
- 如果 coordinator 未 ready，注册 pending intent。
- ready 后自动执行一次，不要求打开远控页。
- 页面销毁时取消只属于该页面的 listener，不取消设备级 bootstrap。

页面最小集合：

- 使用统计。
- 模型/供应商。
- 技能。
- 插件。
- MCP。
- 命令。
- 子代理。
- 钩子。
- 记忆。
- 索引。
- 设置/通知/安全。

### 7.2 读写边界

读方法可以在 capability manifest 验证后自动调用。写方法必须同时具备：

1. 在本机当前 app.asar/真实桌面版本中确认方法。
2. 脱敏 fixture。
3. 参数 schema 校验。
4. request receipt 或明确 error。
5. UI 显式确认具体影响范围（停止操作除外，因为用户已经预授权）。

未满足条件的功能显示“原生只读/接口未验证”，不要显示会失败的开关。

### 7.3 设置

设置页打开即加载当前设备/工作区状态：连接、通知模式、截图策略、指纹锁状态、电池优化、语言、主题、诊断。设置卡片应以“当前值 + 来源 + 最后同步 + 操作”呈现，避免只有一个开关却不知道是否写成功。

## 8. 视觉与可访问性

### 8.1 设计语言

借鉴 WorkBuddy 的信息组织方式：任务优先、工作区分组、状态 pill、清晰的空态和紧凑的底部输入区。不得复制 WorkBuddy 品牌、专有 icon、二进制、页面源码或文案；参考文件仅存放在交接 ZIP 的 reference 目录。

视觉基线：

- 8dp 网格；主要横向 padding 16dp。
- 触控目标至少 44dp，重要按钮 48dp。
- 标题、正文、辅助文字至少有明显层级，不用超大图标撑空白。
- 单一强调色；运行中、成功、警告、错误四类语义色保持一致。
- 轻量边框和分隔线优先于多层阴影/巨型圆角卡片。
- 支持深色和浅色主题；颜色只走主题 tokens。

### 8.2 屏幕安全与截图

普通对话、设置和工作台允许系统截图。检查并移除全局 FLAG_SECURE；敏感信息通过以下方式保护：

- 日志脱敏。
- 链接/凭据不渲染完整值。
- 生物识别锁只保护进入敏感操作，不禁止全 App 截图。
- Android 最近任务预览按用户设置脱敏。

### 8.3 通知

安静模式下：

- 不显示常驻“后台守护中”通知。
- 事件只写通知栏，不主动打开页面或抢焦点。
- 应用回到前台时补同步未读事件。

持续连接模式下必须使用合规前台服务通知，并让用户知道代价。事件通知和前台服务通知使用不同 channel；不得用高重要性 channel 把所有事件强制弹成悬浮窗。

### 8.4 无障碍

- 所有 icon button 有中文 tooltip/semantic label。
- TalkBack 能读出连接状态、模型、思考级别、上下文和主动作。
- 动态字体放大到 200% 不截断主动作。
- 键盘/外接设备支持 focus traversal 和 Enter 发送。
- 高对比度状态不只依赖颜色。
- 错误、loading、stale 状态通过语义树播报一次，不循环播报。

## 9. 验收总表

以下均必须在自动化测试和手工/真机证据中通过：

1. 打开支持 Relay 的设备，首屏就是统一 ConversationShell。
2. Relay ready 但 Agent handshake 未完成时，不显示“可发送”。
3. 新会话创建成功后仍在同一个 shell，标题和 sessionId 原地更新。
4. 发送一次只出现一条用户消息和一条对应 Agent 轮次。
5. 模型目录、真实思考选项、上下文 used/max 自动出现。
6. 单独修改模型和思考级别，成功后重新读回权威值。
7. 点击停止立即执行，无确认弹窗且不会重复发请求。
8. 使用统计、模型、插件、MCP 页面不打开 WebView 也能自动加载。
9. 进程恢复、Relay 重连、迟到回执不会覆盖新状态。
10. 普通界面可截图；凭据、日志和通知内容按策略脱敏。
