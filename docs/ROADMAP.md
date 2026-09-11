# 路线图与当前状态

> 本仓库是 [pjpv/zremote](https://github.com/pjpv/zremote) 的延续开发：在原"扫码导入 + WebView 会话"基础上，把它重造成接近 WorkBuddy 移动端体验的 **ZCode Control**。

## 产品定位

- **不是** WebView 套壳，而是"原生壳 + 按需 WebView"的混合形态
- 数据全部来自 ZCode 桌面端官方 remote/v4 桥接流量的被动解析（详见 [ZCODE-PROTOCOL.md](ZCODE-PROTOCOL.md)）
- UI 参考 WorkBuddy 移动版的设计语言（卡片流 / 状态胶囊 / 底部 Tab），详见 [WORKBUDDY-REFERENCE.md](WORKBUDDY-REFERENCE.md)

## 分期计划

### Phase 1 —— 壳重构（已完成）

- **底部 5 Tab 导航**：任务 / 工作台 / 通知（未读徽标）/ 设备 / 设置
  - 支持 Relay 的设备由原生通道维持并行连接；旧版或不支持 Relay 的链接才保留 WebView 兼容页
- **任务 Tab**：跨设备任务卡流（sessionIndex 合并，按今天/昨天/更早分组，状态胶囊 + 审批/输入计数徽标）
- **通知中心 Tab**：跨设备事件时间线（与系统推送同一事件源，进入即清未读）
- **工作台 Tab**：桌面端 14 个设置面板的移动原生版（九宫格入口 + 渐变卡），已实现模型 / 用量统计 / 子代理 / 技能 / MCP / 插件 / 命令 / 钩子 / 记忆 九个面板页
- 设备页设置入口改为 Tab 化，设置页支持 embedded 模式

### Phase 2 —— 原生详情与预热（已完成）

- **原生会话页**（`lib/ui/conversation_page.dart`）：
  - 历史分页与实时订阅，原生渲染正文 / 思考 / 工具调用 / 待办 / 授权
  - 用户明确点击后可发送消息、回应授权或停止当前执行
  - `session_detail_page.dart` 仅保留旧调用方兼容，新导航不再经过嵌套详情页
- **面板预热机制**（`lib/services/warmup.dart`）：
  - 注入钩子只录制明确面板路径的 GET/HEAD（拒绝 POST/body/未知 origin，去重、上限 48 条）
  - 按设备安全存储；下次页面加载后自动重放，面板数据"进 App 即有"
  - 回答了"能否进 App 同时加载所有页面"：设备并行已做到；面板数据可预热重放；**会话正文是单 activeTaskId 订阅，只能后台轮询、无法并行**（协议硬限制）

### Phase 3 —— 真·客户端（原生主流程已落地）

> 静态分析：[NATIVE-CLIENT-FEASIBILITY.md](NATIVE-CLIENT-FEASIBILITY.md)
> **实测验证（以这篇为准）**：[RELAY-PROTOCOL-VERIFIED.md](RELAY-PROTOCOL-VERIFIED.md)
>
> 结论：**原生直连可行，且已用真实二维码链接跑通**——握手、取工作区、开工作区桥、
> 收帧并回执全部成功。静态分析里有 7 处推断被实测推翻，详见验证文档第九节。

**已完成并验证的模块**（`lib/relay/` 与原生 UI）

| 模块 | 内容 |
|---|---|
| `relay_proof.dart` | HMAC-SHA256 + base64url 无填充（服务端已接受） |
| `relay_link.dart` | 链接解析（`sid`/`hash`/`t`/`mid`/`name`/`app_version`） |
| `relay_frame.dart` | 信封 / 握手消息 / rpc-frame 解析、WireBase64、CRC-32 |
| `rpc_assembler.dart` | 分片重组、缺口检测、上限保护、超时清理、重传去重 |
| `relay_socket.dart` | WS 抽象 + `dart:io` 实现（可注入 HttpClient） |
| `relay_channel.dart` | 握手、心跳、RPC 配对、自动回 ack |
| `relay_bridge.dart` | 引导编排、Agent RPC、会话历史/实时更新与用户命令 |

**关键实测结论**

- QR 流程走**单条 WS**（`wss://zcode.z.ai/ws?mid=…`），**不用任何 REST**
- 上行 `zcode_type` 负载必须套 `{type:'data', payload, client_ts}` 外壳，否则 `WRONG_PARAM`
- 握手字段**平铺在顶层**，不在 `payload` 里
- 必须回 `rpc-frame-ack`，否则桌面端按同一 `messageSeq` 反复重传
- 帧内 `checksum.crc32` 与标准 IEEE CRC-32 一致（已验证）
- 客户端类型枚举含 `mobileApp`，原生 App 属被预期形态

**当前实现与剩余验收**

- Relay 帧已完成组装与 Agent RPC 解码；原生任务列表、会话正文、实时更新和命令层已接入。
- 设置里的技能、MCP、插件、命令、子智能体、钩子、记忆、用量与索引库均进入原生页面；
  未核验的写接口保持只读，不显示假开关。
- 通知已改为低重要性、无声音、无震动、无悬浮提示；Android 合规要求的前台服务只保留通知栏静默状态项。
- 真机 Relay / 后台恢复 / 生物识别最终验收按用户要求暂时停止；iOS release 构建仍需 macOS/Xcode 环境。

**要认的风险**

- 服务端对握手时序/频率的容忍度未知（字段名已确认，但边界行为需继续试）
- `deviceSid` / `passHash` 由桌面端生成，我们只消费不自造
- v3/v4 并存即协议会变的证据；原生直连等于焊死某个版本
- relay 单配对：同一台桌面同时只能一个手机页面
- 这是未公开的内部接口，个人自用与再分发性质不同，对外发布前需评估

## 工程状态

- 测试数量与 `flutter analyze` 结果由 CI 的实际运行输出为准，不在文档中硬编码数量。
- 当前工作区使用 D 盘工具链完成了 `flutter analyze`、`flutter test` 与 Android release 构建；
  iOS release 仍需 macOS/Xcode，真机验收暂按用户要求暂停。

## 已修复的历史问题

1. **通知打扰**：所有事件通知切换为低重要性静默通道；前台服务也使用低重要性通道，不显示“正在后台守护中”
2. **切换设备重新握手**：支持 Relay 的设备不再同时创建 WebView 与原生通道，避免同一 sid/hash 触发“其他设备接管”
3. **设置页底部 App 区域**：压成单行 `ZCode Control vX · github.com/2421873411a-rgb/ZCode-Control`
4. **任务卡跳转丢失**：壳重构时 `PendingSessionJump` 消费端被丢，已补回（session_view `ref.listen`）
