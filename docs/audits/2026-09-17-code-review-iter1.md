# 零上下文架构与核心正确性审计报告 — ITERATION 1（2026-09-17）

> 审计代理：code-reviewer（零历史、只读；无 Bash，未复跑测试）。审计对象：W-001（C2a 子 frame 取证计数器）+ W-002（D-20260916-15 notifier 修复）批次。
> 结论：**需要修改**——1 个 P2（F-1，本轮新引入）+ 4 个 P3；核心行为等价性、生命周期清理、notifyFrom 修复、诊断包合并均验证通过。

## 问题清单

### P2

- **[F-1][P2] shouldOverrideUrlLoading 子 frame 分支新增 ref/widget 访问，无 mounted 守卫** — lib/ui/official_remote_page.dart:1741-1752
  改动前该分支是纯函数；接入 record() 后成为回调里唯一的 provider 访问点。同文件 onLoadStart/onLoadStop 在使用 ref 前均有 `if (!mounted) return;`，此处缺失。generation 重建/页面卸载后残余子 frame 回调到达时，State 已卸载 → riverpod 抛 "Cannot use ref after the widget was disposed"；异常发生在 return 之前，整次导航决策丢失，flutter_inappwebview native 侧收不到结果时的默认策略待确认（若默认放行，一次本应 CANCEL 的子 frame 导航被放行，涉及 W1 白名单语义）。
  建议修复：决策无条件返回，计数仅在 mounted 时记。

### P3

- **[F-2][P3] NT501 的 reason='show' 对构造失败有误导** — lib/services/notifier.dart:310-316
  spec 构造与 _plugin.show 共用同一 catch，统一落 reason='show'；l10n/脏 summary 导致的构造失败被记成"展示失败"，triage 方向误导。修复本身完备：try 之前无任何可抛调用。
- **[F-3][P3] 诊断包子 frame 计数合并逻辑无测试** — lib/ui/diagnostics_page.dart:122-131
  _buildBundle 的并集合并是 widget 私有方法，无任何用例断言诊断包含 subFrameTotal/Allowed/Cancelled。当前实现正确（BridgeSchema.statsKeys 白名单不含 subFrame*，JS 侧无法伪造；...? 空值展开安全），但回归无防护。
- **[F-4][P3] coveredProviders 一致性测试偏弱（既有测试）** — test/protected_wipe_test.dart:119-133
  仅 containsAll 且不含 subFrameStatsProvider；不锁新键，也不断言擦除后为空。
- **[F-5][P3/观察，非本轮改动] 主 frame 拦截日志与注释表面矛盾** — lib/ui/official_remote_page.dart:1758-1766
  注释称"只记录 path"，代码传 uri?.toString()。实际安全——AppLog 写入前对 LogField.route 统一过 LogRedactor.route（去 query/fragment），sid/hash 不会落盘。风险在防线是间接的：未来绕过 AppLog 直接消费该值即泄漏凭证。建议改为 uri?.path 与注释一致。

## 核对通过项

- 计数状态机并发语义：record() 同步读改写 + 整体 map 替换，单 isolate 内原子；空 deviceId 拒记、forget no-op 有测试锁定。
- 生命周期三清理点与 observerStats 逐点对称、无遗漏：设备删除（session_pool）、换凭证（didUpdateWidget）、擦除（protected_wipe），全局 grep 无第四类删除路径。
- 诊断页渲染：三行仅数字，设备 id 经 LogRedactor.shortId 截短；无零计数幽灵行。

## 不变量表

| # | 不变量 | 结论 |
| --- | --- | --- |
| 1 | 子 frame 放行/拦截决策与改动前逐 URI 等价 | PASS*（判定复用既有 isTrustedOrigin，被 link_builder_trust_test 锁定；*无 shell 无法跑 diff 对照，标待确认） |
| 2 | 计数只含数字，不引入 URL/host/内容 | PASS |
| 3 | 设备生命周期三清理点齐全 | PASS |
| 4 | notifyFrom 不再向外抛异常 | PASS |
| 5 | 诊断包既有字段不受影响 | PASS |

## 覆盖与未覆盖

实际审计：subframe_stats / official_remote_page（全文）/ session_pool / protected_wipe / diagnostics_page / notifier / link_builder / observer_stats / bridge_schema（statsKeys 段）/ diagnostics_bundle / webview_sync（notifyFrom 调用处）/ structured_log + app_log（定位段）/ 三个测试文件。
未覆盖：git diff 逐行对照（无 shell）；插件 native 侧回调抛错默认策略；flutter analyze/test 未运行；Android native 侧。
