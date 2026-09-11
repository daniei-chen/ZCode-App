# 原生客户端可行性调研：remote/v4 到底是什么接口

> 调研对象：ZCode 桌面端 v3.11.2（`<ZCODE_INSTALL>`，Electron，`resources/app.asar`）+ 服务端页面 `https://zcode.z.ai/remote/v4`。
> 方法：离线静态分析 app.asar 内的 bundle + 拉取服务端页面及其 JS bundle 阅读。
> 所有结论来自对**已发布产物**的观察，不涉及破解、不绕过任何鉴权。

## 一、结论先说

**可以。** 手机端不是"网页套壳"，它的数据通道是一条**标准 WebSocket + 一组 REST 接口**，凭证就是二维码链接里的参数。

原生 App 完全可以直连，**不需要 WebView**。需要复刻的东西只有三样：

1. 三个 REST 调用 + 两条 WebSocket
2. 一套 HMAC-SHA256 握手（算法已完整拿到，见第五节）
3. `rpc-frame` 分片数据帧的解析/组包（第六节）

## 二、整体架构（关键：手机不直连桌面）

```
        ┌──────────────────────── zcode.z.ai relay ────────────────────────┐
        │                        wss://zcode.z.ai/ws                       │
        └───────▲──────────────────────────────────────────────▲───────────┘
                │                                              │
   桌面端 ZCode  │  /ws?mid=<deviceMid>                          │  手机
   (role=device) │  header X-Device-ID                            │  (role=terminal)
                │                                              │
        ┌───────┴────────┐                          ┌──────────┴──────────┐
        │ main 进程       │                          │ /ws/remote-control/ │
        │ web-remote-     │                          │ window/{token}      │
        │ control 模块    │                          │ + /api/remote-      │
        └────────────────┘                          │ control/*           │
                                                    └─────────────────────┘
```

这解释了之前的一个困惑：**手机和桌面往往不在同一局域网，却都能用**。因为双方都是"出站"连到公网 relay，由 relay 配对转发。这也解释了为什么 `wss://zcode.z.ai/ws` 这个常量同时出现在桌面端和手机端页面里。

对应的 i18n 文案印证了这套模型（`out/renderer/assets/IntlProvider-*.js`）：

- `webRemoteControl.description`：扫码或在手机上打开链接，即可远程控制当前工作区
- `webRemoteControl.failure.relayUnavailable`：外部 relay 连接不可用，请确认桌面端在线后重试
- `webRemoteControl.failure.desktopDisconnected`：桌面端已经断开连接
- `webRemoteControl.singlePageNote`：当前 relay 配对同一时间只支持一个手机页面
- `webRemoteControl.failure.sessionConflict`：这个链接已经被其他页面占用
- `webRemoteControl.failure.kicked`：relay 已踢出这次配对

## 三、端点全表（已确认）

服务端端点由 app.asar 中的一处常量表决定（`out/main/chunk-WR3FEWGO.js`、`out/host/chunk-RWMCBKS2.js` 等文件里各有一份同样的实现）：

```js
origin:                    https://zcode.z.ai
apiBaseUrl:                https://zcode.z.ai/api/v1
remoteUrl:                 https://zcode.z.ai/remote/v4     // appVersion 达标用 v4，否则 v3
webRemoteCallbackUrl:      https://zcode.z.ai/web-remote/callback
relayWsUrl:                wss://zcode.z.ai/ws
zcodePlanOpenAiBaseUrl:    https://zcode.z.ai/api/v1/zcode-plan
zcodePlanAnthropicBaseUrl: https://zcode.z.ai/api/v1/zcode-plan/anthropic
zcodePlanBillingCurrentUrl:https://zcode.z.ai/api/v1/zcode-plan/billing/current
```

手机端实际只用到下面这些（全部以 `relayOrigin` 为基址）：

| # | 方法 | 路径 | 说明 |
|---|---|---|---|
| 1 | `GET` | `/api/remote-control/windows/bootstrap/{token}` | 返回 `{workspaces, tasks, mobileViewState:{activeWorkspaceKey, activeTaskId}}` |
| 2 | `WS` | `/ws/remote-control/window/{token}` | 首帧必须收到 `{type:'window-control-ready', windowControlSessionId, mobileConnectionId}` |
| 3 | `POST` | `/api/remote-control/windows/{token}/workspace-bridge` | 头带 `X-ZCode-Mobile-Connection-Id`；体 `{workspaceKey, taskId?}`；**返回 `{wsUrl}`** |
| 4 | `WS` | 第 3 步返回的 `wsUrl` | 工作区数据通道，跑 `rpc-frame` |
| 5 | `POST` | `/api/remote-control/windows/{token}/mobile-view-state` | 头同上；体 `{activeWorkspaceKey, activeTaskId?, updatedAt, deviceInfo}` |
| 6 | `POST` | `/api/remote-control/platform/{token}` | 体 `{method, args}` → `{result}`；把桌面端 IPC 桥搬到 HTTP 上 |
| 7 | `WS` | `/ws/remote/{remoteId}` | 另一条直连 relay 的通道（页面 URL 带 `?remote=` 时走这条） |

第 5 个端点特别值得注意：**我们现有 App 的 `zrViewState` 钩子抓的就是它**。也就是说，我们现在是靠 WebView 代理这个 POST，而原生实现里这只是一次普通的 HTTP 请求。

## 四、鉴权模型

凭证是**二维码链接里的参数本身**，不是登录态：

- `remoteControlToken`（query）→ 用于第 1/2/3/5/6 号端点，直接拼在路径里
- `relayOrigin`（query，可缺省为页面 origin）→ 服务端地址
- 页面 URL 里还有 `?remote=<remoteId>` 这种形态，走 `/ws/remote/{remoteId}`

页面代码里明确有一个白名单集合 `new Set(['remoteControlToken','relayOrigin'])`，说明这两个就是被官方认可的入口参数。

**没有 OAuth、没有 JWT、没有设备指纹校验参与远控链路**（OAuth 只用于 `/web-remote` 那个"控制台登录"分支，跟手机远控是两条路）。

> 边界说明：链接即能力（bearer capability）。拿到链接就能连——这是官方设计，不是我们绕过了什么。但也意味着**链接泄露 = 控制权泄露**，原生实现必须把 token 当密码存。

## 五、握手（原生 App 要复刻的核心）

### 5.1 桌面端（role = `device`）

```
1. WS 连接  wss://zcode.z.ai/ws?mid=<deviceMid>
            header: X-Device-ID: <deviceMid>
2. 发 device_register ──► 收 device_register_ack { device_sid }
                          存 { deviceSid, passHash }
3. 发 auth_init { type:'auth_init', device_sid, ... }
4. ◄── auth_challenge { nonce }
5. 发 auth_response {
       type: 'auth_response',
       device_sid,
       proof: calculateProof(passHash, nonce, 'device', deviceSid),
       client_ts
   }
6. ◄── auth_ack / pair_status_ack { pair_status }
7. 之后进入 data 帧交换 + 心跳 pair_status_query
```

### 5.2 手机端（role = `terminal`）

流程完全一样，**只有 role 字面量不同**，并且 `deviceSid` / `passHash` 来自链接参数而不是注册返回值：

```
auth_init {
  type: 'auth_init',
  role: 'terminal',
  device_sid: <链接里的 deviceSid>,
  meta: { platform:'web', version:<appVersion>, name:'mobile-browser' },
  client_ts: Date.now()
}

auth_challenge → { nonce }

auth_response {
  type: 'auth_response',
  device_sid,
  proof: calculateProof(passHash, nonce, 'terminal', deviceSid),
  client_ts
}
```

### 5.3 proof 算法（已完整拿到，可直接用 Dart 实现）

服务端页面里的实现：

```js
async function calculateProof(passHash, nonce, role, deviceSid) {
  const key = await crypto.subtle.importKey(
    'raw', utf8(passHash), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const sig = await crypto.subtle.sign('HMAC', key, utf8(`${nonce}|${role}|${deviceSid}`));
  return base64url(new Uint8Array(sig));   // 无填充，+→- ，/→_
}
```

即：

```
proof = base64url( HMAC-SHA256( key = passHash, msg = "{nonce}|{role}|{deviceSid}" ) )
```

Dart 侧 `package:crypto` 的 `Hmac(sha256, key).convert(utf8.encode(msg))` 即可，base64url 无填充手工处理。**这一段没有任何黑盒。**

### 5.4 心跳与状态

握手后有 `pair_status_query` 轮询与 `pair_status_ack` 回执，页面里可读到 `heartbeatIntervalMs`（默认 10s）、`reconnectJitterMs`（上限 2s）。断开后按抖动间隔自动重连。

## 六、数据通道：`rpc-frame`

工作区数据走第 4 号 WS，帧格式（从 asar 内的 zod schema 反推）：

```
外层信封： { type, payload, client_ts, server_ts }

payload 两种形态：
  { zcode_type: 'rpc-frame',
    bridgeSessionId, bridgeGeneration?, recoveryId?,
    seq, messageSeq,
    fragmentIndex, fragmentCount, messageBytes?,
    dataBase64 }

  { zcode_type: 'rpc-frame-ack', bridgeSessionId, ..., ackMessageSeq }
```

要点：

- **分片**：`fragmentCount > 1` 时按 `fragmentIndex` 重组，`dataBase64` 是 base64 的 UTF-8 负载。我们现有 WebView 钩子已经实现了同样的重组逻辑（`asm` 槽位 + 上限 32 个并发逻辑帧）。
- **校验**：`isCanonicalBase64` + `crc32`；还有 `chunked` / `snapshot` / `fragment` / `deltas` / `complete` / `staging` / `committed` 等传输态。
- **上限**：`maxPhysicalFrameBytes`（按物理帧字节数预检）、`maxFragments`、`transportEnvelopeIdMaxChars`。
- **降级**：`bridge-degraded`，原因枚举 `rpc-transport-fault` / `rpc-frame-gap` / `buffer-overflow` / `buffer-timeout`，带 `seq` / `expectedSeq` / `droppedCount`。

### 负载操作全集（`zcode_type` 之外的消息名）

```
workspace.upserted / workspace.removed
task.upserted      / task.removed
session.upserted   / session.removed
row.upserted / row.removed / row.delta / row.appended
turn.started / turn.terminal
stream.chunk
tool.lifecycle
subagent.lifecycle
permission.lifecycle
model.request.status
usage.delta
config.updated / state.updated
compaction.terminal
```

### 客户端 → 桌面端的指令（原生会话已接入）

```
resolveInteraction     ← 批准/拒绝待办交互（原生批准的入口）
inputAccepted          ← 输入被接受
inputDisposition       ← 输入处置
editUserQuery          ← 编辑用户提问
applyFileRewind        ← 回滚文件
```

`resolveInteraction` 的存在意味着：**原生批准不需要"驱动 DOM 点按钮"，可以直接发协议帧**。这比我原先设想的 DOM 方案干净得多，也不受页面改版影响。

## 七、这条路能买到什么

对比现在的 WebView 方案：

| 维度 | WebView（现状） | 原生直连 |
|---|---|---|
| 进 App 即加载所有页面 | 做不到（单 `activeTaskId` 订阅，被页面实现限制） | **可以**——自己控制订阅，可并行拉多个会话 |
| 会话正文 | 只能看 WebView | **可原生渲染**（`stream.chunk` / `row.*` 直接给数据） |
| 原生批准 | 得驱动 DOM | **直接发 `resolveInteraction`** |
| 直发指令 | 得驱动 DOM | **直接发 `inputDisposition` 等** |
| 后台/锁屏保活 | 靠 WebView 常驻，耗电 | 只维持一条 WS，省电得多 |
| 稳定性 | 页面改版就崩 | **协议改版就崩**（同样的风险，但可控性更强） |
| 实现成本 | 已完成 | 需要重写数据层 + 解析层 |

## 八、做不到 / 要认的账

1. **`/ws/remote/{remoteId}` 与 `/ws/remote-control/window/{token}` 的服务端语义**只从客户端调用处推断得出，服务端实现不可见。握手字段名是确定的，但服务端对 `client_ts`、频率、字段顺序的容忍度未知，需要真机试验。
2. **`deviceSid` / `passHash` 的生成规则在桌面端**（`onRegisteredAuth` 回调里落盘）。我们只需要**消费**链接里的值，不需要生成——但如果想自己造链接，就必须逆向注册流程。
3. **协议会变**。v3/v4 并存本身就是证据（`appVersion` 达阈值才走 v4）。用原生直连等于把自己焊死在某个版本上。
4. **合规边界**：这是官方未公开的内部接口。个人自用与再分发是两个性质，对外发布前应评估。
5. **单配对限制**：relay 同一时间只允许一个手机页面。原生 App 多设备并行时，每台桌面各开一个配对即可，但不能对同一台桌面开多个。

## 九、建议的落地路径

不要一步推翻 WebView。建议**双通道并存**，原生直连先作为"增强通道"：

- **Step 1 — 打通只读通道（低风险）**
  原生实现第 1/2/3/4/5 号端点 + 握手 + `rpc-frame` 解包，把 `workspaces/tasks/sessionIndex` 数据接到现有 `session_index` 层。此时 WebView 仍在，数据可交叉校验——**两条路对不上就说明解析错了**，这是最安全的验证方式。

- **Step 2 — 原生化会话列表与详情**
  数据到位后，任务 Tab / 详情页脱离 WebView 数据源。

- **Step 3 — 指令通道（高风险，但比 DOM 干净）**
  发 `resolveInteraction` 实现原生批准，发 `inputDisposition` 实现直发指令。

- **Step 4 — 可选：去掉 WebView**
  只有当原生通道稳定覆盖全部场景后才考虑。保留一个"打开网页版"的逃生入口。

**建议先做 Step 1 的手脚架，并且保留 WebView 做对照。** 手上有真实载荷才能确认字段名——目前 5.x 节的握手是确定可实现的，6 节的负载结构是确定但字段名需真机核对。

## 十、复现本次调研的方法

```bash
# 1. 列出 asar 内文件
python tools/asar_list.py "out/main"

# 2. 按内容检索（命中位置映射回文件路径）
python tools/asar_grep.py -c "zcode.z.ai" "rpc-frame" "device_sid"

# 3. 按精确路径提取（产物仅入 tools/，被 .gitignore 排除，不入库）
python tools/asar_get.py out/main/index.js out/host/chunk-RWMCBKS2.js

# 4. 拉取服务端页面与其入口 bundle
curl -sL -o web/remote_v4.html "https://zcode.z.ai/remote/v4"
curl -sL -o web/entry.js "https://zcode.z.ai/remote/v4/assets/index-nOVzQNKW.js"
```

> 提取到的 bundle 属第三方专有产物，**只留在本地 `tools/`，不进入版本库**；本文件只记录结论。
