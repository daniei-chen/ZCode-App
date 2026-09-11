# ZCode Control 架构（当前实现）

## 总体形态

Flutter App（Android 优先），单进程，原生主流程 + 明确的兼容渲染：

```
AppShell (IndexedStack)
├── NativeDeviceView × N   ← 支持 Relay 的设备主界面（不创建 WebView）
├── SessionView × N        ← 仅旧版/不支持 Relay 的设备兼容页面
├── TasksPage              ← 任务 Tab（跨设备任务卡流）
├── PanelsPage             ← 工作台 Tab（桌面端设置面板的移动原生版）
├── NotificationsPage      ← 通知中心 Tab（跨设备事件时间线）
├── ManagePage             ← 设备 Tab（扫码/粘贴导入、拖拽排序）
└── SettingsPage(embedded) ← 设置 Tab
```

- 底部 `NavigationBar` 索引 = `设备数 + Tab 序`（`RootTabs` 统一换算）
- `ActiveTabNotifier`：切换即落盘 lastDeviceId；`clampTo` 在设备增删时兜底
- 支持 Relay 的设备只建立一条 native bridge；同一份 remote/v4 sid/hash 不再被
  WebView 与 Relay 同时占用，避免 `session-conflict` / “其他设备接管”
- WebView 保留为旧版设备与用户明确选择的兼容入口；不参与原生设备的默认主流程

## 数据链路（核心）

原生设备的数据来自 remote/v4 的 Relay 协议；兼容设备才从 WebView 页面桥接：

```
EventObserver.hookScript（AT_DOCUMENT_START 注入）
├── 包装 window.fetch      → 响应体 / mobile-view-state 请求体
├── 包装 WebSocket         → WS 帧（含 base64 rpc-frame 解码、分片重组）
├── 包装 EventSource       → SSE 消息
└── 通道：zrEvents / zrViewState / zrWs / zrSeen（面板请求录制）
        ↓ (RelayBridge / JS handler)
RelaySourceNotifier._ingestNativePayload / SessionView._onBridgeMessage
├── PanelDataNotifier.ingest        ← 模型/额度/子代理/技能等面板快照（关键词预筛 512KB 上限）
├── SessionStateExtractor           ← 会话状态（标题/阶段/待交互计数/工作区/时间戳）
├── TaskIndexExtractor              ← task.upserted / removed / archived / snapshot
├── StateDiffer                     ← 状态差分 → 事件（approval/completed/error/resolved）
├── EventFeedNotifier               ← 未读徽标 + 等待批准红点 + 事件历史（通知中心数据源）
└── NotifierService                 ← 系统推送（NotificationGate 判定：前台可见会话不推）
```

原生会话正文链路：

```
RelayBridge
├── helloConversationV4 → initializeConversationV4
├── conversationRowsRangeV4       ← 历史分页
├── subscribeConversationV4       ← 实时更新
└── sendConversationCommandV4     ← 用户明确触发的 sendText / stop / resolveInteraction / 配置切换
        ↓
ConversationNotifier → ConversationPage（消息、思考、工具、待办、授权、输入框）
```

支持 Relay 的设备进入原生会话页后先展示“新对话”编辑器；历史会话由抽屉按工作区
归类。发送使用官方 `sendText` 命令并等待 `accepted/noop` 回执，附件先经
`attachmentBeginV4` / `attachmentChunkV4` / `attachmentCommitV4` 上传后再随消息发送。

设置里的 Agent 能力不再依赖“先打开网页面板”：
`skills.list`、`mcp-sync.listLocalUserMcpCandidates`、
`plugin-management.getPluginsOverview`、`subagents.list`、`hooks.loadHooks`、
`memory.listProjectMemories`、`usage-stats.getAppUsageStats` 和 `setting.get`
均通过原生 service RPC 按需读取。未核验的写接口不显示假开关，也不自动执行。

### 面板预热（warmup.dart）

- `zrSeen` 通道只录制明确面板路径的 GET/HEAD（拒绝 POST、body 和未知 origin；去重、48 条上限）
- 按设备持久化到 secure storage（`zremote.warmup.<id>`）
- 仅兼容 WebView 页面在 onLoadStop 后重放（1.8s 后启动、140ms 间隔、credentials: include）
- 重放脚本再次检查当前 origin，并且只发 GET/HEAD；链接更换或删除设备时清空旧记录
- 响应被既有 fetch 拦截接住 → panel_state 自然吃饱 → 工作台"进 App 即有数据"

### 会话跳转（PendingSessionJump）

- 任务卡 → 直接进入 `ConversationPage`；消息/工具/授权/输入框都在原生页完成
- 只有不支持 Relay 的旧设备才通过明确的 WebView 兼容入口写入 `PendingSessionJump`

## 通知链路

- 四类通知统一使用 `*_quiet_v2` 低优先级通道；关闭声音、震动与 ticker，避免 heads-up
- 通知只新增到通知栏并保留角标；Android 8+ 通道设置持久化，因此升级使用新 channel id
- 后台前台服务保留 Android 合规所需的常驻通知，但为 `IMPORTANCE_LOW`、静默、无角标，
  文案不再显示“正在后台守护中”
- `NotificationGate`：App 在前台且事件属于当前可见会话 → 不推送
- `resolved` 事件自动撤回对应待审批通知（stableId 由 device.id+type+taskId 哈希）
- 设置页：系统权限告警条（OS 权限关闭时直达系统设置）+ 测试通知入口（链路自检）
- MainActivity MethodChannel（zremote/app）：openNotificationSettings / areNotificationsEnabled / MIUI 白名单引导

## 关键模型

- `SessionState`：sessionId / title / phase / sessionEnded / permissionCount / userInputCount / interactionKind / toolName / description / lastActivityAt / workspace / workspacePath / pinned
- `PanelSnapshot`：providers（含 isCurrent）+ plan + quotas + usage + subagents + listPanels（skills/mcp/plugins/commands/hooks/memory）
- `FeedEvent`：type / at / taskId / sessionTitle / summary（每设备 50 条上限）
- 双语：`app_zh.arb` / `app_en.arb`，gen-l10n 生成（`lib/l10n/*.dart` 不入库）

## 构建

- Flutter ≥ 3.47；JDK 17；AGP 8.11.1 / Kotlin 2.2.20 / compileSdk 36 / minSdk 24
- `flutter build apk --release` 产物在 `build/app/outputs/flutter-apk/`
