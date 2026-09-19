# ITERATION 12 深探审计（WebView/网络面 + 状态/持久化面）

- 日期：2026-09-19
- 方式：两路零上下文 code-reviewer（审计范围见下）+ 主代理逐条验证
- 检查点：cp-11-iter11 基线（revision 12）
- 覆盖：RESILIENCE / BOUNDARY_CONTRACT / SCALE_DATA / LIFECYCLE_RESOURCE

## 审计范围

- 路 A（WebView + 网络面）：official_remote_page / event_observer / webview_sync /
  session_jump / in_page_back / link_builder / bridge_message_pipeline / update_service
- 路 B（状态 + 持久化面）：lib/state/ 全部 + device_store / diagnostics_bundle /
  observer_alerts / device_connectivity / page_refresh_policy / warmup / structured_log

## 结论一览

| 编号 | 发现 | 级别 | 裁定 |
| --- | --- | --- | --- |
| N-P1-1 | `_takeoverLogged` 跨 generation 不重置：第二次顶号不再落 `webviewTakeoverDetected`，排障第一现场丢失 | P1 | **证实，本轮修**（_armBootCover 重置 + 源码钉） |
| N-P1-2 | `restoreLast()` 与 deviceListProvider 异步加载竞态，冷启动不恢复 lastDevice | P1 | **证伪**：app_shell 在 `prev.isEmpty && next.isNotEmpty` 转换上触发 restoreLast（app_shell.dart:260-264），恰在列表就绪之后 |
| N-P1-3 | 重启后 StateDiffer 基线为空 → 仍 pending 的审批红点复现 | P1 | **裁定为既定设计**：event_feed.dart:107-113 注释明确 resolved 记账与 unread 分离；重启后对仍 pending 项重新提醒与 dedupe 窗口的进程内语义一致；prefs 关闭时事件不进 feed，无幽灵红点 |
| N-P2-1 | `_pageStateTimer` 800ms 周期探针揭盖后永不停止：N 台设备 = N 个后台定时器，退后台也空转 | P2 | **证实，本轮修**（三处揭盖点 `_disarmCoverWatch()`，`??=` 重建 + 源码钉） |
| N-P2-1b | OB201 的 `sseMessages` 是死输入（JS 侧从不 bump，SSE 只计 sseIgnored），留在 consumedKeys 误导维护者 | P2 | **证实，本轮修**（迁入 ignoredKeys，evaluate 仍读；键集合护栏测试自动适配） |
| N-P2-2 | `probeUri` 探测裸 host 根路径，官方下线 /remote/vN 但保留站点根时绿点与远控页可用性背离 | P2 | **证实，本轮修**（探测目标改为控制链接同路径、去 query；测试更新） |
| N-P2-3 | session_index 两表独立计 5000，`_rebuild` 合并视图可达 2×上限（敌对页两侧各灌唯一 id） | P2 | **证实，本轮修**（合并后再次 `_evictOverflow`，钉住保护不变；doc 注明） |
| N-P2-5 | event_feed `pendingByTask` 是状态面唯一无硬上界的表（键=页面上行 taskId） | P2 | **证实，本轮修**（硬上限 2000、超限压到 7/8、最新写入键受保护；规模测试钉） |
| N-P2-6 | `normalizeVersion` 无结尾锚：`v1.2.3-rc.1` 与 `1.2.3` 同值、`v9.9.9-beta` 参与升级比较 | P2 | **证实，本轮修**（结尾锚定，带后缀 tag 一律非法 fail-closed；与 W-021「更新 tag normalize」合并闭环） |
| N-P3-2 | warmup 收录带 query 的 GET：query（搜索词/分页参数）原样进安全存储并被重放 | P3 | **证实，本轮修**（query/fragment 一律不收录；warmup 覆盖面小幅收窄，如实记录） |
| A-P2-2 | JS 观测面在 hidden/cover 期间不降频（WS 解码、15s 遥测照跑）——与后台通知可靠性需产品权衡 | P2 | **候选化 W-025**（需真机窗口验证通知链路，本轮不动） |
| A-P2-3 | `mediaPlaybackRequiresUserGesture: false` 过宽；非 http scheme（tel:/mailto:）静默 CANCEL 无用户反馈 | P2 | **候选化 W-027**（改默认值需真机 smoke 验证官方页视频，阻塞于 BL-003） |
| A-P2-4 | 更新链信任根 = GitHub 账户安全：digest 与 APK 同源同通道，SHA256 只防传输损坏 | P2 | **如实边界**：现有链（https 白名单 + 必带 digest + 强制比对 + 包名/versionCode/签名预校验）代码层已闭环；发布源投毒超出代码层，候选化 W-029（内置公钥验签，需用户拍板供应链姿态） |
| A-P3-2 | `onRenderProcessUnresponsive` 只记日志不自动恢复 | P3 | **候选化 W-028**（自动重建策略需真机证据） |
| 清扫 | l10n 死键 189 个（conversation*/panel*/tab* 等被 v1.0.0 WebView 化裁掉的功能遗留）；`session_index.dart:265` 硬编码 '未命名工作区'（其消费链 SessionGrouping.groupByWorkspace 在 lib 内已无调用方） | P3 | **候选化 W-026**（机械清理批，本轮已饱和不扩面） |

## 已核对无问题（审计确认，附证据）

- WebView 安全设置面：fileAccess/contentAccess/mixedContent/多窗口/第三方 cookie 全部默认关闭，UA 桌面化为功能需要（official_remote_page.dart:1632-1664 与插件默认值逐一比对）
- 桥闸完整性：8 个 handler 首行 `_bridgeAllowed`（令牌+URL 双闸），POST 主 frame 不注令牌
- JSON 深度 64 预扫状态机逐行走查（含字符串内括号不计数）；4MiB 上限 JS/Dart 双侧
- 渲染进程死亡恢复链：错误卡→重试→generation++→令牌轮换→bootstrap 重注，闭环
- Dart 侧 Timer 总账（除 N-P2-1 外全部有 cancel 路径）；JS 侧 4 个 interval 随文档销毁
- 下载器：逐跳白名单重定向、416/206/200 分支、续传起点校验、超限清理闭环
- Riverpod 无循环重建（provider 间全 read，watch 仅 UI 层）；全仓无 .family provider
- 设备库 partial write：secure storage 单键整 JSON + 解析失败隔离，半个 JSON 不会崩
- 诊断包红线：输入类型层面挡自由文本，日志行写读双侧过 LogRedactor，canary 零泄漏
- 7 个 OB 码与触发点一一对应（除 N-P2-1b 占位键）
- protected_wipe 时序与 fail-closed 语义、WebView 会话不残留

## 本轮修复清单（详见 EVIDENCE E-45 / mutations/iter12.json 21 条变异）

代码：official_remote_page（N-P1-1/N-P2-1）、observer_alerts（N-P2-1b）、
device_connectivity（N-P2-2）、session_index（N-P2-3 + W-021 bidi 清洗）、
event_feed（N-P2-5 + bidi）、update_service（N-P2-6）、warmup（N-P3-2）、
bridge_health（W-021 死条件）、structured_log（W-021 代理对）、
notification_prefs/device_store（W-021 alertMode/startupTarget 白名单归一）、
biometric/main（W-021 单调时钟：Stopwatch 取代墙钟，防回拨续期 relock 窗口）、
app_settings（W-021 通知状态 fail-closed）、root_tabs→pending_session_jump（W-021 命名）、
session_pool/diagnostics_bundle/diagnostics_page（W-018b 设备库完整性计数入诊断面）。

测试：iter12_hardening_test.dart（19 例）、manage_page_write_failure_test.dart（W-018a
改名/删除写失败 widget 测试 ×2）、device_connectivity_test / diagnostics_bundle_test 更新。

## 独立复核轮（iter12-r1，零上下文 code-reviewer）

主代理修复批完成后，零上下文复核代理对全部 diff + 变异语料 + 测试做终审，返回"需返修"，发现全部当轮闭环：

| 复核发现 | 级别 | 处置 |
| --- | --- | --- |
| 变异语料 3 条 find 串不唯一（mutate.py 要求 count==1：disarm 锚、biometric `if (ok) {`×2、manage SnackBar×3）且其中 manage 条锚在 add 路径（测试走 rename/remove，永远杀不死） | P1 | 语料重写：disarm/biometric 加上下文锚；manage 拆成 rename/delete 两条注释锚唯一变异；全 25 条锚预检唯一性后重跑 |
| N-P2-5 阈值带无钉：`if (pending.length <= max) return` → `if (pending.isEmpty) return` 变异存活（每次插入都压到 1750 仍满足 `≤2000` 断言） | P1 | 测试补阈值带断言（上限-1 个键必须原样保留），变异下 1750≠1999 必红 |
| 盖板竞态（复核 P2）：deadline 揭盖 `_disarmCoverWatch()` 后，横跨 20s 刻度的在途探针返回可把盖板重新盖上且计时器已停——弱网/离线场景永久品牌盖；同族：同 generation 重挂后被陈旧探针立即揭盖 | P2 | `_coverEpoch` 纪元护栏：揭盖/重挂都递增，探针 apply 前校验纪元，陈旧结果一律丢弃（源码钉 + 变异钉） |
| Stopwatch 单调钟在设备深睡期冻结（不含 suspend），息屏数小时后 relock 双判定全过——相对旧墙钟实现是收紧方向的回退 | P2 | `BiometricService.relockEvidence = max(单调, 墙钟)`：两钟各自在"深睡/回拨"一种场景失真且方向互补，取大者两洞同堵；残余边界（回拨恰逢深睡）已记录——此时设备在系统锁屏之下，非 App 门禁独立攻击面。单元测试钉两场景 |
| P3×6：errorText/_boundedTitle 代理对漏网（同 `_clip`）、_evictOverflow 第二轮 O(n²)、合并驱逐视图级语义未注明、擦除未清 integrity provider、`lastSuccessAt` 无消费方易被复用、`_hiddenSince` 仍墙钟 | P3 | 前五项当轮修（共享 clipCodeUnits、Set 化驱逐、注释、wipe 覆盖清单+清除序列、用途注释）；`_hiddenSince` 候选化 W-030 |

复核确认无问题项：_disarmCoverWatch 残余调用早退安全、_capPending 三性质独立成立、_sanitize identical 零拷贝、诊断包新增两行满足红线、normalizeVersion 收紧与 `/releases/latest` 单 tag 扫描路径兼容（GitHub latest 本就跳过 prerelease；注意 `v1.2.3+21` 形态 tag 会被判非法——当前 tag 契约 vX.Y.Z 不受影响）、源码钉相对路径在两条管线稳定、root_tabs 改名全仓零残留。

## 候选化（本轮不实施，登记待办）

- W-025（P2）：JS 观测面 hidden/cover 降频（WS 解码转发、1Hz 握手扫描、15s 遥测照跑）——需与后台通知可靠性做产品权衡 + 真机验证
- W-026（P3）：l10n 死键 189 个清理 + session_index 硬编码 '未命名工作区'（其消费链 SessionGrouping 已无 lib 内调用方，一并核实）
- W-027（P2，阻塞 BL-003）：`mediaPlaybackRequiresUserGesture` 改 true 需真机 smoke；tel:/mailto: 静默 CANCEL 增加用户反馈
- W-028（P3，阻塞 BL-003）：onRenderProcessUnresponsive 自动恢复策略（现只记日志等用户手动）
- W-029（P2，需用户拍板）：更新包发布源验签（内置公钥，minisign/cosign）——防"GitHub 账户失陷同时换 APK+digest"
- W-030（P3）：`_hiddenSince` 改单调/双钟口径（UX 级，回拨只影响静默刷新时机）
