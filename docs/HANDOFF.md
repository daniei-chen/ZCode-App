# 交接说明（HANDOFF）

> 目标：换一台电脑也能直接接着干活。本文覆盖**项目现状、环境搭建、架构、下一步、踩过的坑**。
> 最后更新：2026-09-10

---

## 〇、参考来源与本机 ZCode

协议和数据结构以本机 ZCode 桌面端为准；交接时保留来源，但不要把桌面端安装包、远控链接或凭证放进源码包。

| 来源 | 已核实位置 / 说明 |
|---|---|
| 本项目 | 当前仓库源码、测试、文档 |
| ZCode 桌面端 | `<ZCODE_INSTALL>/resources/app.asar`（本机安装目录，作为协议/schema 参考） |
| 上游原项目 | `https://github.com/pjpv/zremote.git`，只作参考，不向上游推送 |
| 远控链接 | 仅保存在本机忽略路径；它等同密码，不入库、不分享 |

需要核对官方行为时，先从桌面端 `app.asar` 和真实响应样本确认，不凭名称猜接口。`reference/`、`env/`、APK/native 二进制等交接材料不进入本项目的源码交付包。

## 一、这是什么

**ZCode Control** —— 一个把 ZCode 桌面端的「移动端远程控制」能力做成**原生 App** 的客户端。

官方的手机远控是个网页（WebView）。这个项目把它换成原生 Flutter 界面：
原生任务列表、原生会话正文（含工具调用/思考/待办）、原生批准操作、原生设置面板。

连接方式：扫码拿到链接 → 用链接里的凭证走官方 relay 协议 → 与桌面端直连。
**不经过任何第三方服务器**，数据只在你的手机和你的电脑之间流转。

### 关键定论（早期走过弯路，这里先立住）

**「帧是二进制所以做不了原生 UI」——这个结论是错的。**
二进制只是会话层的编码方式，任务列表等一批数据本来就是 JSON，且二进制本身
**已被完全逆向并实现**。所以原生 UI 没有技术障碍。

---

## 二、当前状态（2026-09-11 九小时迭代后）

状态以**自动化测试 + fake relay 契约测试**为事实源；“真机”一列如实标注未执行。

| 能力 | 代码/自动化 | 真机 |
|---|---|---|
| 连接 / HMAC 握手 / 断线重连 | ✅ 四层 readiness（Transport→Agent→Workspace→Session ack），旧 epoch 结果丢弃，重连后 stream 自动重绑（F07/F13） | ⏸ 未执行 |
| 任务列表（跨设备） | ✅ 原生 Relay 数据层 | ⏸ 未执行 |
| 统一会话 shell（draft = 同一页面） | ✅ 首屏即 ConversationShell，无独立新对话页 | ⏸ 未执行 |
| 创建会话 | ✅ clientOperationId 作 commandId，回执丢失按 task index 找回，不重复 create（F04/F05） | ⏸ 未执行 |
| 会话正文（正文/思考/工具调用） | ✅ 单一 reducer，五级 identity，推送/拉取/乐观行不重复（F06、S05 重放） | ⏸ 未执行 |
| 发送 / 停止 | ✅ 发送状态机 + 乐观行；停止无确认框、每连接 epoch 只发一次（F12）；无固定延时刷新 | ⏸ 未执行 |
| 模型 / 思考 / 上下文 | ✅ 来自 `readSession` 权威快照；思考选项为动态数组（含 `max`）；`setModel`/`setThoughtLevel` 独立写；拒绝显示 reasonCode（F08–F11） | ⏸ 未执行（写协议为 app.asar schema 验证，未真机回执） |
| **批准与拒绝** | ✅ 代码完成 | ⏸ 未执行 |
| 工作台（usage/模型/技能/插件/MCP/命令/子代理/钩子/记忆） | ✅ relay 设备全部走原生 service RPC 页面，按设备隔离，Agent 就绪后自动加载，无“去远控页”文案 | ⏸ 未执行 |
| 通知 | ✅ 事件通道低重要性静默；持续连接模式默认关闭（安静模式） | ⏸ 未执行 |
| 截图 | ✅ 源码无 FLAG_SECURE（测试守门） | ⏸ **需真机复现**“不允许截图”的根因 |
| usage 脱敏 | ✅ 显式数值/布尔 allowlist | — |
| 主题（日间 / 夜间 / 跟随系统） | ✅ | — |

**规模**：`flutter analyze` 0 issues；`flutter test` 629 passed（CI 以实际输出为准）。
Android release 1.5.0+8 已在 D 盘工具链构建并 apksigner 验证（见 `docs/PROGRESS-9H.md` 最终摘要）。
iOS release 仍需 macOS/Xcode；真机 Relay / 后台恢复 / 生物识别最终验收按用户要求暂停。

---

## 三、环境搭建

### 3.1 需要的东西

| 组件 | 说明 |
|---|---|
| Flutter SDK | 本项目在 Windows 上用的是解压版，未走官方安装器 |
| Python 3.11+ | 只用于仓库外的辅助脚本（解析 asar、协议解析） |
| Node 18+ | 仅当需要用浏览器抓包时才需要 |

### 3.2 本机实际使用的位置（换机后按自己情况调整）

```
Flutter SDK : `<TOOLS_ROOT>/flutter`
PUB_CACHE   : `<TOOLS_ROOT>/pub-cache`
Python      : `<PYTHON_ROOT>/python.exe`
```

### 3.3 ⚠️ 必须知道的环境坑

**在 Git Bash 里直接跑 `flutter` / `dart` 会失败**，因为它们依赖 Windows 环境变量。
实测可用的调用模板（照抄即可）：

```bash
export PUB_CACHE=<TOOLS_ROOT>/pub-cache
export NO_PROXY=localhost,127.0.0.1,::1
DART="<TOOLS_ROOT>/flutter/bin/dart"
F="<TOOLS_ROOT>/flutter/bin/flutter"

env "PROGRAMFILES(X86)=C:\\Program Files (x86)" \
    "PROGRAMFILES=C:\\Program Files" \
    "SystemRoot=C:\\Windows" \
    "windir=C:\\Windows" \
    "ComSpec=C:\\Windows\\System32\\cmd.exe" \
    "$F" test
```

其他注意事项：

- 首次 `flutter pub get` 会下载依赖，**需要能访问网络**
- `flutter analyze` / `flutter test` 每次约 1–2 分钟，建议放后台跑
- 中文路径 / 中文参数：**用 Python 写临时文件，不要用 heredoc**，
  heredoc 会吃掉一层反斜杠，导致 JSON 解析失败（踩过）

---

## 四、架构

```
lib/
├── models/            数据模型（纯数据，可单测）
│   ├── resource_list.dart   设置面板通用模型（筛选/分组/计数）
│   └── skill.dart           技能（容错解析）
├── relay/             官方 relay 协议实现 —— 项目核心
│   ├── relay_link.dart      链接解析（sid/hash/mid）
│   ├── relay_proof.dart     HMAC-SHA256 凭证
│   ├── relay_frame.dart     帧信封 + WireBase64 + CRC32
│   ├── rpc_assembler.dart   分片重组
│   ├── relay_channel.dart   握手 / 心跳 / RPC 配对 / 回执
│   ├── relay_bridge.dart    引导编排 + 会话命令
│   ├── agent_rpc.dart       ★ 二进制 RPC 编解码（逆向所得）
│   └── conversation_row.dart 会话正文行模型
├── state/             Riverpod 状态层
├── ui/                界面
└── theme.dart         双主题调色板（ThemeExtension）
```

### 4.1 两条数据通道（重要）

```
relay 地址（wss://zcode.z.ai/ws）
   │
   ├─ 非帧负载（JSON）────────→ 任务列表、工作区、桥就绪
   │     zcode_type: workspace-list-response 等
   │
   └─ rpc-frame（二进制）─────→ 会话正文、工具调用、设置类面板
         内含 agentService RPC，需用 agent_rpc.dart 编解码
```

**两条通道的编解码完全不同**，不要混用。

### 4.2 二进制 RPC 格式（逆向所得，务必看文档）

```
请求  04 04 06 <kind>  06 <varint seq> 01 <len> <service> 01 <len> <method> <args>
响应  04 02 06 <type>  01 06 <varint seq> 05 <varint len> <json>
```

- 第二字节：请求 `04`、响应 `02`，**不能混解**
- `kind`：`0x64`('d')=调用，`0x66`('f')=事件订阅
- `type`：`0xC9`=成功，`0xCA`=失败
- 值标签：`0x01`=字符串，`0x05`=JSON

**三个硬约束（都踩过）**：

1. `dataBase64` 必须是**标准 base64 且带填充**（实测官方 117 帧：86 帧含 `=`、
   4 帧含 `+/`、**0 帧含 `-_`**）。用 URL-safe 会被判 `rpc-transport-fault`
2. 解码要**同时接受标准与 URL-safe**，否则桌面端 1000+ 字节的正文帧会被整条丢掉
3. JSON 参数要传 **Map/List，不要自己 `jsonEncode`**，否则会被打成字符串标签

细节与实测样本见 `docs/RELAY-PROTOCOL-VERIFIED.md`（第八节）。

### 4.3 会话层握手（顺序不能错）

```
1. workspace-list-request      → 拿任务与工作区
2. workspace-bridge-open       → 开桥
3. zcode-agent.helloConversationV4()
4. ⚠️ clientKind 必须按 hello 返回的 clientMode 推导：
   clientMode === 'desktop-continuous' ? 'desktop' : 'web'
   实测是 web-remote-replayable → 必须发 'web'
   硬编码 'mobileApp'（枚举里合法）会直接导致 rpc-transport-fault
5. subscribeConversationV4 / conversationRowsRangeV4
```

⚠️ **响应不能按 seq 配对** —— 桌面端回的是它自己的计数器，不回显请求序号。
要按内容匹配（如 `kind == 'hello'`）。

---

## 五、调试工具

仓库外的 `tools/` 目录（**含凭证，不随包分发**，这里说明怎么重建）：

| 工具 | 用途 |
|---|---|
| `relay_probe.dart` | 真机联调探针：连接 / 拉任务 / 拉正文 / 批量调方法 |
| `ws_hook_proto.js` | 浏览器里挂钩 WebSocket（抓官方页面协议） |
| `since.js` / `since.py` | 增量抓取并解码官方页面上行 |
| `asar_list.py` / `asar_get.py` / `asar_grep.py` | 读 Electron asar（挖官方 schema） |

### 5.1 探针用法

```bash
# 连接并拉任务列表
dart run tools/relay_probe.dart tools/relay_link.local.txt

# 拉会话正文
dart run tools/relay_probe.dart tools/relay_link.local.txt --conversation

# 批量验证服务方法（binary=agent RPC，platform=platform-request）
dart run tools/relay_probe.dart tools/relay_link.local.txt --batch tools/method_probe.txt
```

⚠️ 探针踩坑：连续调用会出现 **off-by-one**（上一条响应被下一条吃掉，
因为响应没有可关联字段）。判断归属要**以返回内容的形状为准**，不要只看顺序。

### 5.2 怎么拿链接

在 ZCode 桌面端打开「移动端远程控制」，扫码或复制链接，存到
`tools/relay_link.local.txt`（**该文件已被 .gitignore 排除**）。

⚠️ **链接 = 你桌面的控制凭证，等同密码**：
- 绝不提交到版本库、不贴进公开 issue
- 调试完建议在桌面端**刷新二维码**使其失效

---

## 六、剩余工作（按优先级；真机测试当前暂停）

### 1. 真机验证批准流程（恢复测试后再做）

代码已完成，但**没在真机上按过一次**。需要确认的点：

- `permission` 行的 `interactionId` 到底取哪个字段
  （代码做了两级回退：`interactionId` → `toolCallId`）
- `resolveInteraction` 发出去后桌面端是否真的继续执行

命令格式（已在 `relay_bridge.dart` 实现）：

```json
{"type":"resolveInteraction",
 "payload":{"interactionId":"…","answer":{"optionId":"…"}}}
```

经 `zcode-agent.sendConversationCommandV4` 发出，信封：
`{commandId, clientId, sessionId, type, payload, issuedAt}`

⚠️ CAS 类命令（`applyFileRewind` / `forkAssistant` / `editUserQuery` /
`retryTurn` / `setAssistantFeedback`）**必须带 `baseRevision`**；
row target 类须带 `baseLogEpoch`；`resolveInteraction` 两者都不需要。

### 2. 原生 Agent 面板

通用组件已就绪（`models/resource_list.dart` + `ui/resource_list_view.dart`）。
技能、MCP、插件、命令、子智能体、钩子、记忆、使用统计和索引库都已进入原生路由；
未核验的写接口不伪造开关、不在后台自动执行。

对应接口见 `docs/ZCODE-FEATURE-MAP.md` 第 1.1 节，例如：

```
hooks.loadHooks({workspacePath})
memory.loadMemory / getUserMemoryDirectory
subagents.list
usage-stats.getAppUsageStats
```

MCP 本地候选列表与插件概览已接入；后续如需扩展，只补经过确认的安全写操作。

会话页也已完成原生化：支持 Relay 的设备不会再嵌套网页，会直接进入新对话编辑器；
历史会话按工作区归类，正文、思考耗时、技能数量、工具调用、授权、模型、思考级别、
上下文和附件入口均由原生 Flutter 控件承载。发送使用 `sendText` 并等待桌面端回执，
不会把“请求已发出”误报成“发送成功”。

### 3. 实时推送

`subscribeConversationV4` 的历史拉取与桌面端主动推送已统一进入
`ConversationUpdate`，会话页可实时合并更新；主动刷新仍保留作为断线或协议变化时的兜底。

### 4. 其他

- 未核验的资源写接口（例如 `skills.setEnabled`）仍保持只读，避免伪造成功状态
- 会话列表归档 / 置顶 / 未读等官方写接口，待逐个确认 schema 后接入
- 真机 Relay、后台恢复、生物识别和授权写操作最终验收；当前按用户要求暂停
- iOS release 构建验证仍需 macOS/Xcode 环境

---

## 七、约定与红线

### 7.1 设计约定（后续页面请沿用）

- **不用大圆角卡片堆投影**，用**细分隔线 + 留白**做结构
- **单一强调色**，只用在有信息含义处（进行中、用户消息标记、待批准）
- **不用 emoji**；状态用小圆点 + 文字
- 字号梯度克制（15 / 14.5 / 12.5 / 12 / 11），行高 1.5–1.62
- 颜色一律走 `context.zt.xxx`，**不要硬编码**（双主题要能切换）

### 7.2 合规红线（见 `docs/COMPLIANCE.md`）

- **只读优先**；写操作（批准/发指令）必须由用户明确触发，**不做静默自动批准**
- **绝不调用**账户与计费接口（`coding-plan-subscription` 下的
  `payStripe` / `bindStripeCard` / `createEnterpriseOrder` 等 30+ 个）
- 不做通用远控工具、不碰他人会话、不采集上传用户数据

### 7.3 工程习惯

- 新增逻辑尽量下沉到可单测的纯函数（如工具摘要、分组、容错解析）
- 涉及官方 schema 的地方**用真实样本做测试基准**（仓库里已有多个）
- 不确定就**不猜**：宁可在界面上写明"暂不支持"，也不做假更新

---

## 八、文档索引

| 文档 | 内容 |
|---|---|
| `docs/RELAY-PROTOCOL-VERIFIED.md` | 协议实测全记录（连接/握手/帧/二进制 RPC/会话层） |
| `docs/ZCODE-FEATURE-MAP.md` | 功能地图：38 个服务、14 个面板、方法清单 |
| `docs/COMPLIANCE.md` | 合规边界（必读） |
| `docs/RELEASE-CHECKLIST.md` | 发布签名、源码包与验证清单 |
| `docs/HANDOFF.md` | 本文 |

---

## 九、交接检查清单

- [x] `flutter pub get` 成功
- [x] `flutter analyze` 0 issues
- [x] `flutter test` 全绿
- [ ] 真机 Relay / 后台恢复 / 生物识别最终验收（按用户要求暂停）
- [ ] iOS release 构建（需要 macOS/Xcode）
- [ ] `docs/COMPLIANCE.md` 已读
- [ ] 知道链接等同密码，不提交、不外传
