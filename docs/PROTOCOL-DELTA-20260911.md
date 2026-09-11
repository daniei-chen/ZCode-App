# ZCode v4 协议增量记录（2026-09-11 已验证）

本表是证据表，不是猜测。每一行的 schema 都在本机 ZCode 桌面端 bundle 中定位到 zod 定义；空白项标 NOT-VERIFIED。

## 环境

- ZCode app.asar 路径：本机安装目录 `<ZCODE_INSTALL>/resources/app.asar`（307 MB，2026-09-04 构建）
- 桌面端版本：以 bundle 内 `app_version` 为准（链接参数 3.11.x 系列）
- 读取日期：2026-09-11
- 读取方式：Python 直读 asar 头索引，只抽取包含协议标记的 `out/host/*.js` 与 `out/renderer/assets/*.js` chunk 到仓库外临时目录，rg 定位 zod schema；未复制 asar 本体
- 是否真实桌面请求：否（静态 schema 验证；真机回执待用户重新授权后补）
- 是否脱敏：是（fixture 全部为合成值）

## 方法表

| 能力 | service | method | request schema（已验证字段） | response selector | read/write | verified fixture | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Relay handshake | relay | auth_init / auth_challenge / auth_response / auth_ack | 见 RELAY-PROTOCOL-VERIFIED §2 | `type == 'auth_ack'` | read | relay_channel_test 已覆盖 | VERIFIED（历史真机） |
| Agent hello | zcode-agent | helloConversationV4 | 无参 | `kind == 'hello'`，含 connectionId / clientMode / capabilities | read | relay_bridge_test 已覆盖 | VERIFIED（历史真机） |
| Conversation subscribe **ack** | zcode-agent | subscribeConversationV4 | `{topic, base?, visibility?, connectionId, clientMode, workspace?}` | **`{ack:{subscriptionId:string, mode:'snapshot'\|'resume', logEpoch:string}}`** | read | verified/subscribe_ack.json | **VERIFIED（schema）**——订阅成功必须以收到 ack 为准 |
| Subscription update envelope | zcode-agent | （推送） | — | `{topic, subscriptionId, fromSeq, toSeq, sentAt, payload:{kind:'snapshot',snapshot}\|{kind:'deltas',deltas[]}}` | read | — | VERIFIED（schema） |
| Session snapshot | zcode-session | readSession | `{workspacePath, workspaceIdentity?, sessionId, runtimePolicy:'existing-only', deliveryKind?, messageLimit?, afterSeq?}` | `{protocol, session, settings, projection, runtime, messages[], goalStats?, todos?}` | read | verified/session_snapshot_with_runtime.json | **VERIFIED（schema）** |
| Model current + catalog | zcode-session | readSession → `settings.model` | — | `{current:{providerId,modelId,variant?}, available:[{ref, label, providerLabel?, contextWindow?, maxOutputTokens?, reasoning?, disabledReason?, supports*}], lastUsed?}` | read | 同上 | **VERIFIED（schema）**——目录与当前值同一响应 |
| Thought options | zcode-session | readSession → `settings.thoughtLevel` 与 `settings.model.available[].reasoning` | — | `{enabled:bool, current?:string, defaultLevel?:string, available:[{value,label,description?}]}`；每模型 `reasoning:{enabled, levels:[{value,label,description?}], defaultLevel?}` | read | 同上 + session_snapshot_thought_current_only.json | **VERIFIED（schema）**——级别为动态数组，桌面端常量含 `"max"`/`"high"`；**硬编码 none/low/medium/high/xhigh 错误** |
| Context usage | zcode-session | readSession → `projection.contextUsed/contextWindow`（必有）；`runtime.contextUsage:{used,size,cost?}`（可选） | — | 非负整数 | read | 同上 | **VERIFIED（schema）** |
| Token usage | zcode-agent | getTaskTokenUsage | `{sessionId}` | schema 别名 nJ（字段未逐项展开） | read | — | PARTIAL——仅用于兜底，不冒充 context |
| **Set model（独立）** | zcode-session | setModel | `{workspacePath, workspaceIdentity?, sessionId, model:{providerId,modelId,variant?}, runtimeModel?, persistAsWorkspaceLastUsed?}` | `{sessionId, appliedModelRuntimeRevision, changed:bool}` | write | verified/set_thought_level_result.json（同形） | **VERIFIED（schema + renderer 调用点）** |
| **Set thought level（独立）** | zcode-session | setThoughtLevel | `{workspacePath, workspaceIdentity?, sessionId, thoughtLevel:string, expectedRevision?}` | `{sessionId, appliedModelRuntimeRevision, changed:bool}` | write | verified/set_thought_level_result.json | **VERIFIED（schema + renderer 调用点）** |
| Switch model+thought（组合） | zcode-agent | sendConversationCommandV4 `type:'switchModelConfig'` | payload `{provider, model, thought, runtimeModel?}`——三字段必填 | 命令回执 | write | failures/config_rejected.json | VERIFIED（schema）——仅在需要同时改两项时使用 |
| **Command receipt** | zcode-agent | sendConversationCommandV4 | 信封 `{commandId, clientId, sessionId\|null, baseRevision?, baseLogEpoch?, type, payload, issuedAt}` | **`{commandId, status:'accepted'\|'rejected'\|'stale'\|'duplicate'\|'noop'\|'failed', reasonCode?, message?, revisionAtDecision, result?}`** | — | verified/*_receipt.json, failures/config_*.json | **VERIFIED（schema）**——UI 必须展示 reasonCode/message |
| Create session | zcode-agent | sendConversationCommandV4 `type:'createSession'` | payload `{workspaceId, firstInput?:{text, attachments?}, config?:{provider,model,thought,thoughtLevels?,followupMode,mode}, runtimeModel?}` | receipt.result `{type:'createSession', sessionId, input?:{delivery, inputId, messageId?}}` | write | verified/create_receipt.json | VERIFIED（schema） |
| Send message | zcode-agent | sendConversationCommandV4 `type:'sendText'` | 见 relay_bridge.dart（历史真机） | 命令回执 | write | verified/send_receipt.json | VERIFIED（历史真机 + receipt schema） |
| Stop | zcode-agent | sendConversationCommandV4 `type:'stop'` | payload `{expectedForegroundExecutionId?}` | 命令回执（重复 commandId → `status:'duplicate'`） | write | verified/stop_receipt*.json | VERIFIED（schema） |
| Session status | zcode-session | readSession → `projection.status` / `session.status` | — | `'idle'\|'running'\|'waiting'\|'paused'\|'completed'\|'error'` | read | 同 snapshot | VERIFIED（schema） |
| Usage stats | usage-stats | getAppUsageStats | `{range, timeZone}` | schema 别名 tJ（字段未逐项展开） | read | — | PARTIAL——UI 用显式数值/布尔 allowlist，不放行字符串 |
| Skills / Plugins / MCP | skills / plugin-management / mcp-sync | list / getPluginsOverview / listLocalUserMcpCandidates | 见 ZCODE-FEATURE-MAP §1.1 | 现有 parser | read | 现有测试 | VERIFIED（历史真机） |
| workspaceIdentity 字段 | zcode-session | * | 服务层日志写 `workspaceIdentity ?? null` | — | — | — | 可选；现有 readSession 只带 workspacePath 已可用 |

## 对实现的直接约束

1. `subscribed=true` 只能在收到 `ack.subscriptionId` 后置位；未 ack 前显示"正在订阅"，超时置 sessionSubscribeFailed（可重试）。
2. 单独切模型走 `zcode-session.setModel`，单独切思考走 `zcode-session.setThoughtLevel`；只有同时改两项才用 `switchModelConfig`。
3. 思考选项来自 `settings.thoughtLevel.available[]`（或所选模型 `reasoning.levels[]`）；桌面端只回 `current` 时显示只读当前值。
4. 上下文 used/max 取 `projection.contextUsed/contextWindow`；`contextWindow == 0` 视为未返回，显示 `used / —`。
5. 所有写操作解析回执 `status` 六值；`rejected/stale/failed` 保留旧值并显示 `reasonCode`（+`message`）；`duplicate` 视为幂等成功。
6. 模型目录空/缺失与"当前模型"独立呈现；`disabledReason` 非空的模型不可选并显示原因。

## 安全检查

- 已删除 sid/hash/passHash/token：是（fixture 全合成）
- 已删除完整 remote URL：是
- 已删除真实绝对用户路径：是（`<workspace>` 占位）
- 已删除真实消息正文：是（"fixture message"）
- 写方法有 receipt：是（六值 status）
- 未验证写方法是否被限制为只读：是（PARTIAL 项仅读）
