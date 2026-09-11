# ZCode 桌面端 remote/v4 协议审计笔记

> 来源：对 ZCode 桌面端（Electron，`resources/app.asar`）的被动审计 + remote/v4 云端页面流量观察。
> 所有结论服务于"只读解析"，不伪造请求、不绕过鉴权。

## 页面与鉴权

> ⚠️ 本节已按 2026-09 的 v3.11.2 产物修订。早期记录的
> `?sid=…&hash=…&t=…&mid=…&name=…&app_version=…` 是 **v3** 形态；
> **v4 实际参数是 `remoteControlToken` + `relayOrigin`**（另有一种 `?remote=<remoteId>` 形态）。
> 完整端点、握手与 proof 算法见 [NATIVE-CLIENT-FEASIBILITY.md](NATIVE-CLIENT-FEASIBILITY.md)。

- 手机端入口：`https://zcode.z.ai/remote/v4?...`（`appVersion` 未达阈值则回落 v3）
- 桌面端生成二维码 → 手机扫码导入，App 内长期保存凭证重放
- 页面为云端托管（Vite 构建），**手机与桌面都出站连 `wss://zcode.z.ai/ws` relay，由 relay 配对转发**
  —— 双方不需要在同一局域网
- 鉴权是 HMAC 挑战应答，凭证即链接参数（link as capability）：
  `proof = base64url(HMAC-SHA256(passHash, "{nonce}|{role}|{deviceSid}"))`；
  手机端 role=`terminal`，桌面端 role=`device`

## 桥接消息（已验证存在于 asar / 流量中）

| 消息 / 键 | 含义 | zremote 用途 |
|---|---|---|
| `mobile-view-state`（POST） | 手机页向桌面端上报视图状态 | `zrViewState` 通道单独截获；含 `activeTaskId` |
| `workspace-bridge-open` | 打开工作区桥接 | 会话页连接建立 |
| `workspace-reconnect-request` | 桥接重连请求 | 断线自愈观察 |
| `sessionIndex` / 会话状态 | 会话列表（sessionId/title/phase/sessionEnded/lastActivityAt/workspaceId） | 任务卡流数据源 |
| `pendingInteractionSummary` | `{permissionCount, userInputCount}` | 等批准/等输入红点与事件差分 |
| `pendingInteraction` | `{kind, toolName, description}` | 通知摘要文案 |
| `op: task.upserted / task.removed / session.removed` | 任务增删改 | 会话索引维护 |
| `payload.kind = snapshot` + `snapshot.tasks[]` | 任务全量快照 | 首次同步 replaceTasks |
| `result.tasks[]` + `requestId = bootstrap*` | bootstrap 查询结果 | 全量替换（保留 pinned） |
| `topic: conversation/<sessionId>` | 当前活跃会话订阅 | `ActiveSessionExtractor` 识别活跃会话 |
| `membership.archived / pinned` | 任务归档/置顶 | 过滤与分组 |
| `displayStatus: completed/error/running` | 展示状态 → phase 映射 | completedSuccess / error / running |

## 事件类型全集（zremote 已识别）

```
created, prompt_sent, resumed, streaming,
permission_request, permission_resolved,
elicitation_request, elicitation_resolved,
updated, completed, error
```

- 可推送类型（kNotifiableTypes）：permission_request / elicitation_request / completed / error
- `StateDiffer` 由状态差分合成事件：permissionCount/userInputCount 0→N 触发请求事件，N→0 触发 resolved；phase 进入 completedSuccess/completedInterrupted 触发 completed，进入 error 触发 error

## 关键硬限制

- **单活跃会话订阅**：`mobileViewState.activeTaskId` 是单数——remote/v4 页面同一时刻只订阅一个会话的正文。桌面端能"全部展开"因为它是工作区宿主本体；手机端要另一会话正文必须切换 activeTaskId
- WebView 页面本身只有一个 activeTaskId；原生 Relay 则由 App 自己控制
  `subscribeConversationV4`，不再受 WebView 页面层的单会话渲染限制。
- **relay 单配对**：同一时间只允许一个手机页面；已被占用的链接会报 `sessionConflict` / `kicked`
- 面板数据（模型/额度/子代理/技能…）按需拉取，页面不开面板就不推 —— 预热重放（warmup）由此而生

## 工具

`tools/` 下有 asar 解析脚本（asar_list.py / asar_extract.py / asar_find.py），用于从 app.asar 定位与提取文本资源。**提取到的专有资产不入库**，只有本笔记的结论入库。

## 稳定性策略

- 全链路防御式解析：深度受限遍历（≤8 层）、类型白名单、单条消息 4MB 上限
- 面板抽取：关键词预筛（命中才 JSON 全量解析）+ 字段名多候选（如 percent/remaining/ratio）
- 协议变更是最大风险：所有解析器对"没见过的形状"静默跳过，宁可显示空态不崩溃
