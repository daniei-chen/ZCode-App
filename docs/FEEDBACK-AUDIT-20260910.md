# ZCode Control 2026-09-10 真机反馈审计

## 1. 审计结论

本次反馈不是“再润色一下 UI”，而是一次完整的原生会话链路失败。当前版本把四个不同层次的状态混在了一起：

1. Relay WebSocket 是否建立。
2. Agent RPC 是否完成服务握手。
3. 会话正文是否已经订阅并能读取。
4. 当前会话的模型、思考级别、上下文和工作台资源是否已从桌面端返回。

因此屏幕可以显示“原生通道已连接”，但真正发送时仍会显示“原生通道不可用”；模型 chip 可以显示一次快照里的名称，但模型面板没有可选目录；桌面端拒绝配置变更时，界面只能把失败显示成一条红色横幅。下一轮必须先把状态模型和请求回执统一，再做视觉重构。

审计对象：

- 产品：ZCode Control，Flutter 原生移动端控制器。
- 目标用户：在手机上远程使用本机 ZCode/WorkBuddy 工作区的开发者。
- 关键目标：原生实时对话、工作区/会话索引、Agent 能力、工作台数据、设置和通知都直接来自本机原生通道。
- 当前基线：仓库提交 8c79d3d，已有 Android release APK 1.4.0。
- 证据：用户于 2026-09-10 23:40–23:41 提供的 11 张真机截图；以及源码审查。
- 限制：本次计划阶段不再次连接真机，也不执行 ADB 测试。截图是用户提供的当前版本运行证据，下一位执行 AI 仍须在重新构建后重新截图验收。

## 2. 证据编号

截图在交接包中统一复制到 feedback/current-run/，文件名与原始附件对应如下：

| 编号 | 规范文件名 | 用户看到的事实 |
| --- | --- | --- |
| S01 | 01-new-conversation-create-failed.jpg | 新对话页显示“原生通道已连接”，点击“开始对话”却显示“桌面端未返回新会话”。 |
| S02 | 02-conversation-native-unavailable.jpg | 进入“你好”会话后显示“原生通道不可用，未能发送消息”。 |
| S03 | 03-conversation-config-rejected.jpg | 会话配置变更显示“桌面端拒绝了会话配置变更”。 |
| S04 | 04-model-empty-sheet.jpg | 模型抽屉显示“桌面端尚未返回可选模型”。 |
| S05 | 05-duplicate-messages-attachment.jpg | 同一用户输入和 Agent 回复重复出现；附件也已挂在输入区。 |
| S06 | 06-stop-confirmation.jpg | 停止当前执行仍弹确认框。用户已经明确授权直接停止。 |
| S07 | 07-new-conversation-empty.jpg | 首页是独立的新对话欢迎页，而不是正常会话 shell 的 draft 状态。 |
| S08 | 08-usage-remote-placeholder.jpg | 使用统计页要求先在远控页打开一次面板。 |
| S09 | 09-model-remote-placeholder.jpg | 模型页要求先在远控页打开一次模型菜单/设置。 |
| S10 | 10-plugin-remote-placeholder.jpg | 插件页要求先在远控页打开一次插件面板。 |
| S11 | 11-mcp-remote-placeholder.jpg | MCP 页要求先在远控页打开一次 MCP 面板。 |

截图不应进入 GitHub，也不应把其中的设备名、会话内容或远控凭据重新写入源码；交接 ZIP 中只保留用户已经提供的本地证据副本。

## 3. 问题清单

### P0-NATIVE-001：连接状态与会话可用状态相互矛盾

证据：S01、S02。源码中 relay_source.dart 的 live 状态主要由 RelayBridge phase 驱动，而 conversation.dart 还要额外执行 ensureConversation、subscribeConversation 和正文读取。UI 使用 fromNative、subscribed、isLive 等多个布尔条件，却没有一个可观测的统一 readiness。

用户影响：用户以为“已连接”后点击发送，才发现不能发送。错误提示也无法说明是 transport、agent handshake、workspace 或 session subscription 哪一层失败。

修复验收：

- 连接、Agent 握手、工作区引导、会话订阅分别有明确状态和时间戳。
- 只有 transport + Agent RPC + 会话订阅都成功时，输入框才显示可发送。
- 任何失败都显示可执行的下一步：重试、切换工作区、查看诊断；不显示相互冲突的绿点和红条。
- 同一设备只有一个 bridge owner 和一个连接 epoch。

### P0-CREATE-002：创建会话没有可靠回执

证据：S01。new_conversation_page.dart 直接等待 createConversation 返回 sessionId；任何 RPC 响应匹配失败、服务未 ready、返回形状不符或桌面端已经创建但回执丢失，都会统一变成“未返回新会话”。

修复验收：

- 创建请求拥有 requestId、客户端操作 ID 和 连接 epoch。
- 回执支持已验证的 ZCode v4 返回形状，并通过本机 app.asar 实际字段确认。
- 桌面端已创建但回执迟到时，能从任务/会话索引按 client operation ID 或最近时间窗口恢复，而不是重复创建。
- UI 保留草稿和附件，不因失败清空输入。
- 每次创建最多一次写请求；重试按钮有幂等保护。

### P0-SEND-003：发送失败与消息重复渲染

证据：S02、S05。conversation.dart 在发送前挂订阅，发送后又做延迟刷新；ConversationRow 当前的去重主要依赖 rowId、entityId、toolCallId。桌面版本可能返回缺少这些字段的 userInput/assistant 行，导致推送、receipt、刷新结果被重复并入。

修复验收：

- 建立统一 ConversationIdentity/canonical key：优先官方 row ID，其次 entity/tool ID，最后才使用稳定的 session + role + timestamp bucket + normalized content hash，并记录低置信度。
- 推送、拉取、乐观行和 receipt 都经过同一 reducer，不能由 UI 各自追加。
- 同一消息的状态更新替换原行，不产生第二个气泡。
- 测试覆盖“推送先到、刷新先到、receipt 先到、无 rowId、跨分页边界”五种顺序。

### P0-CONFIG-004：模型、思考级别和上下文不是一个权威快照

证据：S02、S03、S04。当前 ConversationRuntimeConfig.parse 可以读取部分 current 字段，但模型目录只从若干候选路径扫描；思考选项在 conversation_page.dart 中硬编码为 none/low/medium/high/xhigh；updateRuntimeConfig 要求 provider、model、thought 全部已有，且 model/thought 同时发出，桌面端不接受时无法呈现真实原因。

修复验收：

- 服务发现先获取 capability manifest，再选择真实的 model catalog、current config、thought options、context usage 方法。
- 目录和当前值有独立的来源、revision、时间戳、是否过期字段。
- 思考级别来自所选模型的 capabilities，不能凭经验补 hardcode；若桌面端未返回，显示“未提供”而不是虚构选项。
- 上下文显示 used/max/threshold；缺任何字段都分别标明未返回，不能用配额或消息长度冒充 context。
- 配置变更使用桌面端要求的最小 patch，带 revision/etag（若协议提供），成功后重新读权威快照。
- 单独切模型或单独切思考级别都可验证，失败保留旧值并显示具体 RPC 错误。

### P0-WORKBENCH-005：工作台和 Agent 能力依赖被动打开远控页

证据：S08–S11。现有页面虽然有 native service 调用，但部分面板数据仍依赖 bridge payload 被动扫描；页面级 initState 的单次请求不能保证 relay 尚未 ready 时会成功。空页面文案还明确引导用户去远控页打开。

修复验收：

- App 启动时建立一次 BootstrapCoordinator；relay ready 后自动拉取工作区、模型、统计、技能、插件、MCP、命令、子代理、钩子、记忆和索引能力。
- 进入任何页面立即读取缓存并触发 refresh；relay 尚未 ready 时登记意图，ready 后自动完成，不要求用户离开当前页面。
- 每个能力都有 loading、success、empty、unsupported、transport error、stale 六种状态。
- 写操作只有在方法、参数和回执被 fixtures/真机验证后开放；未知写操作保持明确只读，不伪装成已接通。

### P1-IA-006：首页不应有独立的新对话页

证据：S07；源码中 NativeDeviceView 直接构建 NewConversationPage。

目标行为：首页直接是 ConversationShell。没有 sessionId 时只是 draft mode；选择工作区、输入文字、查看当前模型/思考/上下文和发送都在同一个 shell 中完成。成功创建后只更新 shell 状态和标题，不 pushReplacement 到另一套页面。

### P1-COMPOSER-007：发送/停止动作槽位重复

证据：S05、S06。当前 composer 同时显示 stop 和 send 两个 IconButton，附件又在旁边，状态不直观。

目标行为：尾部只能有一个 primary action slot：

- 空闲且无文字/附件：加号/附件。
- 空闲且有文字或附件：发送箭头。
- 发送中：进度指示。
- 桌面端已确认运行：方形停止键。
- 停止请求中：不可重复点击的进度指示。

附件入口可以保留为 composer 内的 secondary affordance，但不能再出现两个相互竞争的主按钮。

### P1-STOP-008：停止操作不应二次确认

证据：S06。用户已明确授权停止执行。

目标行为：点击后立即进入 stopping，发送一次停止请求；失败只显示可重试的 snackbar/banner。去掉是否停止的 modal；通过 haptic、颜色和短暂状态文本提供反馈。防重复点击靠状态机和 requestId，不靠确认框。

### P1-AUTOLOAD-009：页面进入时应自动加载

证据：S08–S11。页面现在能在 initState 中尝试请求，但未与 relay ready 协调，且空文案把用户导向网页。

目标行为：页面打开即显示 skeleton/cache，自动请求；已有缓存先展示并标 stale；刷新按钮只是手动重试，不是首次成功的前置条件。

### P1-PRIVACY-010：截图被系统阻止

证据：用户直接反馈“软件不允许截图”。计划必须检查 Android FLAG_SECURE、WindowManager.LayoutParams、Flutter overlay 和 biometric lock 的关系。普通界面允许截图和系统分享；敏感凭据、远控链接、token 仍然脱敏，不能用全局禁止截图解决安全问题。

### P1-NOTIFY-011：静默后台与通知弹窗策略需要分层

用户早先反馈不希望常驻“后台守护中”通知，也不希望事件被强制弹悬浮窗，只在通知栏新增。

约束：Android 对持续后台 WebSocket 的前台服务通常要求可见 notification，不能通过隐藏通知规避系统规则。下一轮必须提供两个明确模式：

- 安静模式：不常驻前台服务，应用回到前台/系统允许的调度点再重连；事件通知只进通知栏，不主动抢焦点。
- 持续连接模式：用户主动开启，使用合规的低重要性前台通知并清楚说明；事件通知单独使用用户可控制的重要性，不强制 heads-up。

### P2-UI-012：视觉层级和信息密度不足

证据：S01、S07、S08–S11。新对话页把大量空间用于图标和空白；设置/统计/模型页只有居中说明；会话页的状态 banner、消息、composer 和控制 chips 之间没有统一节奏。

目标：采用 WorkBuddy 观察到的任务/工作区/状态信息架构，但不复制品牌、图标、专有资源或页面代码；统一 8dp 网格、可读字号、状态 pill、骨架屏、局部错误和紧凑 composer。

### P2-HISTORY-013：会话需要按工作区分组并按时间排序

目标顺序：

1. 设备。
2. 工作区/项目路径。
3. 每个工作区内按 pinned、运行中/待授权、最近更新时间降序排列。
4. 无工作区路径的会话归入“未归类”，不能丢弃。
5. 标题显示首条用户输入或桌面端标题；同名会话用短 ID 后缀区分。

必须保证排序稳定、跨刷新不跳动、归档/删除/置顶有明确状态和测试。

## 4. 审计后的优先顺序

第一优先级是 P0-NATIVE-001、P0-CREATE-002、P0-SEND-003、P0-CONFIG-004、P0-WORKBENCH-005。它们不通过，视觉重做也只能制造“看起来像能用”的假象。

第二优先级是 P1-IA-006、P1-COMPOSER-007、P1-STOP-008、P1-AUTOLOAD-009、P1-PRIVACY-010、P1-NOTIFY-011。

第三优先级是 P2-UI-012、P2-HISTORY-013，以及更大范围的 Agent 写入能力。

## 5. 本轮审计的完成定义

本审计本身不宣称新版本已修复。下一位执行 AI 必须提交以下证据，才可以把条目标为完成：

- 一段脱敏的 bootstrap 日志，能说明每一层 ready/failure。
- model/thought/context 的实际 request/response fixture 和 parser 测试。
- 一次新会话创建、发送、实时回复、停止的端到端录屏或逐屏截图。
- 统计、模型、插件、MCP 页面在不打开 WebView 的情况下自动出现 loading → data/error 的证据。
- 重复消息、重连、后台恢复、权限审批和截图允许的回归测试结果。
- Android release APK 的版本、SHA-256、签名验证结果。
