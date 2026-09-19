# 返修复核：ITERATION 2 批次（W-003 + W-006）

- **日期**：2026-09-18
- **评审方式**：首轮同一 code-reviewer 子代理续会话复核（只读：Read/Glob/Grep；无 shell，门禁结果按主代理报告采信并做静态推演验证）
- **复核对象**：`D:\tmp\zr\iter2_batch_repaired.patch`（对 iter1 基线导出；3 文件 5 hunk）+ `docs/PLAN-v1.1.0.md:260`
- **前置报告**：`docs/audits/2026-09-18-code-review-iter2.md`（首轮，7×P3，可以合并）
- **返修后门禁**：analyze 0；flutter test **619/619**；对抗验证 ×2 通过

## 逐项复核

| 项 | 结论 | 复核要点 |
|---|---|---|
| F-1 PLAN 文档旧键描述 | **PASS** | 历史句保留、行末追加 iter2 修订句，与文件既有追加式风格一致，与 `event_observer.dart:1668` 实现表述一致 |
| F-3 前缀不误清缺测试 | **PASS** | 用例落地（`event_parser_test.dart:1613-1623`）；独立推演对抗声称：marker 去尾 `\0` 时 `'permission_request\0t10\0'.contains('\0t1')` 为 true → t10 被误清 → 仅该用例失败，N06 用例（仅涉 t1）仍过；计数 618+1=619 自洽 |
| F-4 注释补计数滞后说明 | **PASS** | 主张与代码事实相符：resolved 恒放行并在 prefs 过滤前进 feed（`webview_sync.dart:146-155`）、`event_feed.dart:107-114` 以 pendingTotal 覆写、UI 唯一消费点 `unread_badge.dart:16` 只读在场性 |
| F-5 `onRenderProcessUnresponsive` route 取 path | **PASS** | `:1827` 已改 `uri?.path`，注释指向 D-20260918-01。**debug 级两处保留全 URL 判定"可接受"**：release 在 `AppLog.event` 入口直接丢弃（`app_log.dart:12,29-32`）；debug 构建下 `LogField.route` 仍被 `_normalize` 强制过 `LogRedactor.route`（`app_log.dart:52`），query/fragment 照剥，增量只是 debug 多看到 scheme://host（诊断价值真实）；两处无"只记 path"类注释，不产生漂移 |
| F-2 台账翻转 | 范围外 | 属本轮记账步骤，主代理已完成（D-10 / D-20260917-01 置 closed，EXECUTION_STATE 推进） |

## 新发现

- **N-1（P3，待确认）**：代码注释引用的 `D-20260918-01` 当时尚未在 `docs/DEFECTS.md` 落盘（仅命中代码注释与首轮审计文件）。→ **本轮记账已登记**（closed，注明 debug 两处保留理由）。
- 其余无新问题：patch 范围与处置描述严格一致（无夹带改动）；新测试 reason 中 `\\0taskId\\0` 为展示用字面转义，无害；`onRenderProcessUnresponsive` 改 path 后对 `about:`/`data:`/`javascript:` 的行为与首轮 F-6 分析一致（非回归，`app_log.dart:95` 二次 redact 兜底）。

## 最终结论

**可以合并。** 4 项返修全部 PASS，未引入新问题；唯一跟进项 N-1 已随本轮记账关闭。
