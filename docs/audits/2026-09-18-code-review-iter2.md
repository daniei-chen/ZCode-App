# 代码评审：ITERATION 2 批次（W-003 + W-006）

- **日期**：2026-09-18
- **评审方式**：零上下文 code-reviewer 子代理（只读：Read/Glob/Grep；无 shell，门禁结果按主代理报告采信）
- **评审对象**：净 diff `D:\tmp\zr\iter2_batch.patch`（对 iter1 基线导出 `/d/tmp/zr/ci_iter1_20260916`），3 文件 37 行
  - `lib/services/event_observer.dart`：`EventDedupeGate.keyOf` 去 summary，键 `'${type}\0${taskId ?? ''}\0'`（尾段保留，使 resolved 清理标记 `'\0taskId\0'` 继续整段匹配）
  - `lib/ui/official_remote_page.dart`：`webviewNavBlocked` 的 `LogField.route` 由 `uri?.toString()` 改 `uri?.path`
  - `test/event_parser_test.dart`：+2 回归（轮换 summary 不制造新键；无 taskId 事件折叠为类型级键）
- **对应缺陷**：D-20260916-10（P3，W-003）、D-20260917-01（P3，W-006）
- **门禁（评审前）**：analyze 0 / test 618/618 / JS 49/49 / doc-drift 6/6 / 秘密 0（2 条命中为测试 CANARY）/ OSV BLOCKED（DNS→198.18.0.150，fail-closed）；对抗验证：旧 keyOf 回灌 → 2 条新测试 exit 1

## 结论

**可以合并**。未发现 P0–P2；7 条 P3（4 条建议修、3 条可选/维持现状）。

## 发现

| # | 级别 | 位置 | 问题 | 处置 |
|---|---|---|---|---|
| F-1 | P3 | `docs/PLAN-v1.1.0.md:260` | 里程碑 13 行仍写"相同 (type, taskId, summary) 只放行一次"，与新实现矛盾；doc-drift 门不覆盖此文件 | **已修**：保留历史记录，追加"2026-09-18 iter2 修订：键去掉 summary…（D-20260916-10）" |
| F-2 | P3 | `docs/DEFECTS.md:17,:24`；`EXECUTION_STATE.md:93` | 两条缺陷仍 open、Next action 仍列 W-003+W-006 为候选 | **本轮记账步骤**：置 closed，推进 next_action |
| F-3 | P3 | `event_observer.dart:1689-1692` / 测试组 | 新注释主张"尾 `\0` 防前缀更长 taskId 误清"，但无 `t1`/`t10` 用例；把 marker 简化为 `'\0$taskId'` 时既有套件全绿 | **已修**：新增用例 `allow(perm,t10)→allow(resolved,t1)→allow(perm,t10)` 期望 false；对抗验证：marker 去尾 `\0` → 仅该用例失败（exit 1） |
| F-4 | P3 | `webview_sync.dart:138` + `event_feed.dart:79` | 跨投递"显式事件先到、differ 带 pendingTotal 后到"在窗口内会丢一次计数校准。有界自愈：resolved 恒过闸门且在 prefs 过滤前进 feed，`_ingestResolved` 以 pendingTotal 覆写；UI 唯一消费点 `unread_badge.dart:16` 只用在场性布尔。与台账备选"同 taskId 限频"语义等价 | **已修（注释）**：补"窗口内计数值可能滞后到下一条 resolved 才校准，红点在场性不受影响" |
| F-5 | P3 | `official_remote_page.dart:1825`（另 `:1694`/`:1711` 为 debug 级） | `onRenderProcessUnresponsive` 为 warn 级 release 可见，`route` 仍传全 URL，与 D-20260917-01 同类 | **已修**：`:1825` 改 `uri?.path`，登记 D-20260918-01 随批关闭；`:1694`/`:1711` 为 debug 级（release 直接丢弃，`app_log.dart:29-32`）保留全 URL 的本地诊断价值，不改 |
| F-6 | P3 | W-006 取值语义 | `about:blank`→path `blank`；`intent://` 参数在 fragment 恰被丢弃；`javascript:`/`data:` 载荷在 path 但旧实现同样整体落盘（非回归）且二次 `LogRedactor.redact` 抹 32+ 位 token。信任判定 = 官方 origin + path 正则（`link_builder.dart:53-59`），误拦判别信息就是 path。`log_redactor_test.dart:127`/`diagnostics_bundle_test.dart:96` 是脱敏管线测试，不依赖 UI 传全 URL | 维持现状 |
| F-7 | P3 | 无 taskId 事件折叠 | 生产上无 id 事件到不了闸门（`parseUserActionRoot` 过滤空 id `event_observer.dart:623-626`；differ 事件 id 恒为 sessionId）；测试钉的是闸门级防御契约。不建议"缺 id 时 summary 参与键"（双键语法 + 重开振荡面） | 维持现状 |

## 评审员核查记录（摘要）

1. 键形状/清理/淘汰：marker 对新键精确包含匹配；`t1`/`t10` 碰撞新旧实现无差异（旧键 summary 在尾分隔符之后，同样靠尾 `\0`）；`maxEntries` 淘汰（1710-1717）未触及。
2. 行为权衡：differ 为 0→N 边沿触发，计数未归零不发第二笔；归零必发 resolved → 过闸门 + 清键 + 无条件进 feed。"resolved 字道足以校准"成立。
3. 亮点：新键顺带消除旧实现放大面——轮换 summary 不再能用 256+ 键灌满 `_recent` 把其他任务的合法键挤出去。

## 返修后门禁

analyze 0；test **619/619**（+1 F-3 用例）；对抗验证 ×2 通过；导出副本与工作树逐字节一致。
