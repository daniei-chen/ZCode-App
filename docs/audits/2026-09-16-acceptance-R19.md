# 独立验收报告 — R-19 返修批（2026-09-16）

> 验收代理：test-engineer（零历史）。运行环境：`D:\tmp\zr\baseline_head_16a7d8e`（HEAD 干净导出 + 同步本轮 5 个改动文件；真实仓库只读未动）。
> 结论：**PASS** — 604/604；验收点 B4/B5/B6 与全部返修项逐条有证据；10 条对抗用例 10/10 通过后已删除，`test/` 恢复为原始 46 个文件。
> 前一次运行（并发三代理时）因账号速率限制 `[1302]` 失败未产出结论，本次为单独重派。

## 核对清单

| 项 | 结果 | 证据 |
| --- | --- | --- |
| 一致性：5 个改动文件真实仓库 vs 临时目录 `diff -q` | pass | 全部 SAME |
| `flutter analyze` | pass | No issues found，exit 0 |
| `flutter test` 全量 | pass | `+604: All tests passed!`，exit 0（604 / 0 / 0） |
| B4 同任务审批+输入并存：解决一条不清红点、全清才落 | pass | `event_feed_test.dart:144-170`（含中间态 `{'t':1}` 断言）；`event_parser_test.dart:562-584`（resolved 带 pendingTotal 1/0）；`:523-531` 钉住 2→1 不发 resolved |
| B4 系统通知只在剩余 ≤0 时撤销（原无测试） | pass | 对抗 (g1)/(g2)：在 `testWidgets` 内构造 `WebViewSyncController`，用 `MethodChannel('dexterous.com/flutter/local_notifications')` 探针计数——resolved total 0 时 cancel 调用 >0；resolved total 1（perm 1+input 1 → perm 0+input 1）时 cancel 为 0 且红点 `{'sess_g2':1}` 保留 |
| B5 同投递缺 summary 扁平行不覆盖带 summary 镜像 | pass | `:616-628`（两序）、`:715-723`（webview_sync 实际拼接顺序）；对抗 (c) 反向序亦无事件 |
| B5 跨投递沿用基线 + 同计数镜像不重复发请求 | pass | `:694-713` |
| B5 removed 对账清理粘滞基线 | pass | `:754-763`：5 条扁平行无事件 → removed → resolved(pendingTotal null) |
| B6 removed 路径 resolved 清任务 / 无 taskId 只清 unknown / 无计数显式事件点亮红点 | pass | `event_parser_test.dart:586-592`；`event_feed_test.dart:192-200`、`:227-242`、`:46-54`、`:202-214` |
| 返修：负数 / 1e999 / 小数 / 字符串 / 超大整数过滤或封顶 1024 | pass | 实现 `event_observer.dart:536-554`；测试 `:768-787`、`:789-827`、`:829-848`、`:850-867`；对抗 (a)(b) 用完整 relay 帧复核 |
| 返修：时间戳只认有限值 | pass | `_finiteInt`；`:789-827` 断言 lastActivityAt/createdAt 为 null |
| 返修：dedupe 冲突合并计数 | pass | 实现 `:633-656`；测试 `:869-888`、`:890-899` |
| 返修：`inheritPendingFrom` preview 回退 | pass | `:901-919` |
| 返修：`ingestMessage` 兜底 try/catch → BR202（原无测试） | pass | 对抗 (h)：override 注入 `StateError`，`returnsNormally` 且日志实际输出 `W BR202 event=bridgeMessageDropped reason=ingest_exception` |

## 对抗场景结果

| 场景 | 结果 | 判定 |
| --- | --- | --- |
| (a) 完整帧含 `permissionCount:1e999` | 不抛、计数 0、时间戳 null、无假事件 | 通过 |
| (b) 双 `int.max` 计数 | request 事件 pendingTotal = 2048 且 >0 | 通过 |
| (c) 同投递 [扁平行, 镜像 perm=1]，基线 1 | 无事件 | 通过 |
| (d) 任务行 → 镜像 2 → 扁平行 → 镜像 1 → 镜像 0 | 事件恰为 [permission_request(2), resolved(0)] | 通过（2→1 不发事件为成文设计） |
| (e) resolved 无 taskId 且 total=1，已有条目 | 写 `{'unknown':1}`，unread 不变 | 通过 |
| (e2) 同上但设备完全无 feed | no-op（`current == null` 提前返回） | 可接受行为（见观察项 1） |
| (f) EventDedupeGate 窗口内同键抑制 / resolved 后放行 | 抑制；放行 | 通过 |
| (g1) resolved total 0 | 撤销通知 | 通过 |
| (g2) resolved total 1 | 不撤销 | 通过 |
| (h) 注入异常 | 不外抛、记 BR202 | 通过 |

## 观察项（非阻断）

1. **设备完全无 feed 条目时 resolved(total>0) 为 no-op**：后果受限——红点 UI 只在 unread>0 时显示，unread 只能由白名单事件产生，届时会经计数路径建账。判定：可接受行为。
2. **`EventDedupeGate.keyOf` 含 summary**：summary 变化会绕过窗口抑制再次提醒；键不含 pendingTotal，仅计数变化不解抑制。判定：既有设计（已登记 D-20260916-10）。
3. **测试环境注意**：单测环境下 `flutter_local_notifications` 未注册 Android 实现，`cancel` 为 no-op；观察 `cancelPending` 需先 `AndroidFlutterLocalNotificationsPlugin.registerWith()`。真实 App 不受影响。
