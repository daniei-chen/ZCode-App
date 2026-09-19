# PROJECT_MASTER_PLAN — ZCode App 成熟化蓝图

> 2026-09-16 · 基线 `16a7d8e`（1.0.0+26）· 配套：`PROJECT_AUDIT.md`（现状）、`ACCEPTANCE_MATRIX.md`（验收）、`EXECUTION_PROMPT_9H.md`（施工）
> **持续迭代控制面（2026-09-16 起）**：`docs/continuous-iteration/`（`ITERATION_STATE.json` 为机器权威、`EXECUTION_PROMPT.md` 为每轮执行任务书）；目标档位 release_candidate（85），无预算。
> 原则：同一事实只保留一个权威来源。架构细节以 `ARCHITECTURE.md`、威胁以 `THREAT-MODEL.md`、数据流以 `PRIVACY.md`、协议以 `RELAY-PROTOCOL-VERIFIED.md` 为准；本文只定义**目标状态、边界与门禁**，不复述。

## 1. 产品定位

- **一句话**：把 ZCode 桌面端的移动远程控制页装进手机——扫码接入、多设备并行、审批/完成/失败能提醒、点开直达对应会话，且不复制官方 UI、不碰官方鉴权。
- **主要用户**：自己同时拥有电脑（跑 ZCode 桌面端）与 Android 手机/平板的开发者；一人管多台自有机器。
- **核心业务目标**：离开电脑时不漏审批、不漏失败；回到手机 3 秒内进入正确会话。
- **成功标准（可验证）**：
  1. 审批/输入/完成/失败四类事件在前台（应用内卡）与后台（系统通知）各有一次、且仅一次提醒（F12 幂等）。
  2. 待处理红点与任务真实剩余量一致：同任务多条交互解决一条不清红点，全部解决才清（R-19）。
  3. 门禁、擦除、更新三条安全链路全部 fail-closed，且有运行时测试证明。
  4. 发布产物四重绑定可由第三方脚本复核（`verify-release-artifacts.py`）。
- **明确非目标**：iOS、批量脚本化接管、自建服务端/遥测、常驻前台服务、复刻官方对话 UI、绕过 relay 单配对限制。

## 2. 目标架构

```
┌──────────────────────────── Android 设备 ────────────────────────────┐
│  界面层（Flutter 原生外壳）                                             │
│   AppShell ─ ManagePage(设备) ─ SettingsPage ─ DiagnosticsPage ─ 通知中心│
│   BiometricGate（覆盖全部路由，含 push 路由）  UnreadBadge/浮窗卡       │
│        │ Riverpod 状态：device_list / session_index / event_feed /       │
│        │ active_session / session_status / bridge_health / theme …      │
│  控制层                                                                 │
│   OfficialRemotePage(WebView 宿主，每设备一 generation)                 │
│   WebViewSyncController：桥消息 → decode(1次) → 状态抽取 → StateDiffer  │
│                          → EventDedupeGate(F12) → feed/notify/jump      │
│   BridgeMessagePipeline：schema 校验 + 全链字节预算(R-13) + 分片装配    │
│  核心领域                                                               │
│   RemoteDevice(凭证=控制链接) · SessionState/TaskIndex · ObservedEvent  │
│   DeviceListNotifier 单命令队列(R-06) · ProtectedStateWipe(R-04)        │
│  持久化                                                                 │
│   flutter_secure_storage(设备凭证+索引, readAll 失败不伪装空库 R-05)    │
│   shared_preferences(设置/主题/通知偏好) · WebView 站点数据(清单见PRIVACY)│
│  外部依赖 / 信任边界                                                    │
│   ① 官方远控页(WebView, 唯一 UI 来源；桥令牌+文档信任双校验 F03)        │
│   ② relay WS/REST(只观察，不重放不伪造)                                 │
│   ③ GitHub Releases(更新：出站 URL 策略逐跳校验、SHA256、精确资产名)     │
│   ④ 系统：生物识别/锁屏凭据、通知、安装器                               │
│  身份 / 权限 / 审计 / 秘密                                              │
│   控制链接 = 远程凭据(只在安全存储；日志脱敏 SL*/UP* 事件码)            │
│   生物识别门禁二选一恢复(验证一次 / 擦除放行) · 发布签名仅 CI Secrets   │
│  可观测                                                                 │
│   AppLog 结构化事件码 · observer_stats/bridge_health 诊断页 · 诊断包导出 │
│   无远端遥测(设计) · 备份=用户侧设备重导入(凭证不云备份)                │
└──────────────────────────────────────────────────────────────────────┘
环境差异：dev(模拟器 API 35，debug 签名) · CI(API 30/34 E2E，Secrets 签名) · release(本地/CI 出包，官方证书 07091ffd…)
```

**架构原则落地**：模块化单体（services/state/ui）；官方页是唯一事实来源，`session_index` 只是缓存不冒充账本；外部系统经适配器（`update_service`/`outbound_url_policy`/`bridge_message_pipeline`）隔离；高风险通用能力用成熟库（local_auth、secure_storage、crypto）；关键写入有事务语义（DeviceListNotifier 命令队列、擦除事务、下载续传校验）；动态规则版本化（桥 generation、bridgeGeneration、release-manifest schema）；降级路径明确标识（盖板/冷屏、`unavailable` 恢复面板、`updateOutboundBlocked`）。

## 3. 数据 · 权限 · 安全 · 运维设计（目标状态）

| 域 | 目标状态 | 现状差距 → 动作 |
| --- | --- | --- |
| 待处理交互模型 | 按任务的**权威剩余计数**（permission+userInput）；`resolved` 携带剩余量；缺 summary = 未知而非 0 | 集合制 → **R-19 本轮**（ADR-001） |
| 桥来源校验 | 文档信任 + 主 frame 令牌 + （目标）调用方 frame/origin | 令牌已做；frame/origin 待插件 6.2/补丁 → **ADR-002** 定路线，先取运行时证据 |
| 凭证生命周期 | 导入→安全存储→换链接即重建 generation→删除/擦除全清 | 已做；每设备站点数据隔离未做 → **ADR-004** |
| 门禁恢复 | 读取失败：A 验证一次关开关 / B 擦除放行；双写失败不放行 | 已做；无凭据机型出口 → **ADR-005** |
| 发布信任链 | 签名必需、manifest/sidecar/SBOM/attestation 四重绑定、OSV fail-closed、插件存活门、doc-drift | 机制齐；**CI 实跑证据缺**（外部阻塞）；OSV 公网实扫 → 本轮 |
| 密钥治理 | 密钥仅 CI Secrets + 本地 gitignore；接触面事件必须有处置记录 | 两次事件未处置 → **ADR-003** 交用户拍板 |
| 可观测 | 结构化事件码 + 诊断页 + 诊断包；观察面变化可发现（`sseIgnored` 类计数） | 已做；证据统一登记 `docs/EVIDENCE.md` → 本轮 |
| 日志边界 | 不记控制链接/sid/hash/token；诊断包脱敏 | 已做（log_redactor 测试）；持续回归 |

安全硬门槛（不得越过）：不绕过官方鉴权、不伪造请求、不上传数据、不共享凭据；出站请求仅 https 白名单且逐跳校验、拒绝私网/环回；凭据只从环境/安全存储读取，源码/示例/测试不写可用凭据字面量。

## 4. UI 信息架构与视觉系统

- **路由**：设备页（空态"等待接入设备" / 列表 / 扫码 / 链接粘贴）→ 会话页（WebView + 盖板/冷屏 + 页内返回）→ 设置（主题、通知方式、快速启动、安全与隐私、反馈/联系）→ 诊断（桥健康、观察统计、电池优化、诊断包）→ 通知中心（未读/待处理）。
- **状态覆盖**：加载（冷屏/盖板跟随页面状态）、空、错误（首载 watchdog 有失败出口 F05）、成功、部分成功（`unavailable` 恢复面板）、权限不足（通知/相机权限引导）。
- **视觉系统**：`lib/theme.dart` 单一 token 源；日/夜/跟随系统贯通冷屏与 WebView 主题；固定简体中文；纯图标盖板（不做模板化发光卡）。
- **响应式与无障碍**：手机/平板同路径（页内返回口径统一）；`responsive_layout_test` 4 尺寸 × 3 字体缩放；TalkBack/实体生物识别属用户侧真机验收。
- **真实数据规则**：截图与文档用演示数据并标注；不上传含 `sid`/`hash`/token 的截图。

## 5. 测试矩阵与 SLO

| 类型 | 现状 | 本轮/下一步 |
| --- | --- | --- |
| 单元（领域/解析/预算） | 574 用例，含桥 fuzz、预算探针回归、存储混沌 | R-19 新增：混合 kind 保留、计数直采、假 resolved 防回归、跨投递沿用 |
| 集成（存储/通知/更新） | secure_storage 混沌恢复、更新器混沌（416/私网重定向）、通知撤销重试 | 保持 |
| 契约（注入脚本/发布产物） | JS 门 49 断言、release-manifest schema、sidecar 契约 | 保持；观察面变化告警已落地（W-005，`ObserverAlertPolicy` OB201–OB207，诊断页/诊断包仅枚举码） |
| E2E | `ci-heavy.yml` API 30/34 | CI 实跑后累积"连续 20 次无基础设施超时" |
| 权限/幂等/并发 | 门禁生产拓扑回归、Notifier 三组并发反例、EventDedupeGate 窗口 | 保持 |
| 性能 | 桥字节预算、`pruneOnSnapshot` 基线控制；真机 CPU/内存需实机 | 用户侧 |
| 安全 | log_redactor、outbound_url_policy、OSV 门禁 | 本轮公网 OSV 实跑 |
| 恢复 | 擦除事务、锁屏死锁出口、存储损坏恢复 | 保持 |

**SLO（本项目规模下可验证）**：事件到提醒 ≤ 1 个观察周期（800 ms 探针 + 一次投递）；重复提醒率 0（窗口 2 min 内同键）；红点误清率 0（R-19 测试钉住）；发布产物复核 100% 可脚本化。

## 6. 发布门禁

1. `flutter analyze` 0 + `flutter test` 全绿（当前 574 + 本轮新增）。
2. `node scripts/check_injected_js.mjs` 49/49。
3. 四个发布脚本自测全过；`check-doc-drift.py` 全过。
4. 独立评审闸门（code-reviewer）+ 独立验收（test-engineer）+ 安全体检（security-auditor）三道全 PASS。
5. 出包：先构建后测试（生成文件陷阱）；插件存活门 11/11 + manifest 绑定。
6. 台账 `docs/releases/v1.0.0.md` 与 `docs/PLAN-v1.1.0.md` 同步。

## 7. 路线

| 阶段 | 内容 | 出口 |
| --- | --- | --- |
| **本轮（9h，生产改进）** | R-19 落地 + 独立复审；ADR-001～005；公网 OSV；四份治理文档 + 工作记忆；台账同步 | 全绿 + 三道闸门 PASS；用户拿到 3 个待拍板 ADR |
| **下一阶段** | 用户决策落地（密钥处置、WebView 隔离、无凭据出口）；R-14 按运行时证据实施；~~观察面变化自动告警~~（已落地 W-005，2026-09-18）；资源池/DOM profile | 每项有测试或运行时复现证据 |
| **公开生产** | GitHub 恢复 → 推送 → CI/发布链实跑 → tag 策略 → 真机矩阵/48h soak/TalkBack 归档 → Pre-release → 正式 | `RELEASE-CHECKLIST.md` 全部勾选 |
