# 零上下文架构与核心正确性审计报告 — R-19（2026-09-16）

> 审计代理：code-reviewer（零历史、只读；无 Bash，未复跑测试，只核对用例存在性与断言逻辑）。审计对象：工作区未提交改动（`event_observer.dart`、`event_feed.dart`、`webview_sync.dart` + 两个测试文件）。
> 结论：**可以合并（附建议）**——四条核心不变量在代码与测试中均成立；未发现 P0/P1。返修状态见文末。

## 问题清单

### P0 / P1

无。

### P2

- **[P2-1] `EventParser.dedupe` 会丢掉带计数的 differ 事件，只留无计数的显式事件**（不变量 5）— `webview_sync.dart` 显式事件在前 + `dedupe` 保留首个；显式事件经 `_eventFrom` 构造，`pendingTotal` 恒为 null。
  - 影响：feed 侧 `putIfAbsent(1)` 计数记 1 而非权威 2。红点在场性、resolved 生命周期、系统通知**均不受影响**——resolved 只来自 differ（`'resolved' ∉ kKnownEventTypes`），首个 resolved 即校准计数；通知 stableId 相同不重复。
  - 最小修复：dedupe 冲突时保留/合并带 `pendingTotal` 的副本。
- **[P2-2] 计数未做值域钳制，负数基线可吞掉下一次 0→N 转移**（不变量 7 硬化）— `permissionCount:-5` → 基线 -5 → 随后真实 1 时 `prevPerm == 0` 不成立而漏发 permission_request。
  - 最小修复：提取层 `>= 0` 钳制（负数按缺席处理）。
- **[P2-3] inherit 权威基线的"粘滞红点"窗口未在 ADR 成文** — 权威基线归零出口只有两个：带 summary 的镜像/任务行、removed/archived。若某 workspace 的 sessions-index 增量从此不到达（协议证据不足，待确认），只剩扁平行时每次 inherit 计数 1，永不发 resolved，直到 removed/归档、镜像重现或应用重启。
  - 最小修复：ADR-001"已知限制"成文（现有兜底大概率足够）；硬兜底"连续 N 次 inherit 后降级"有误清风险，需产品确认。

### P3

- **[P3-1] `inheritPendingFrom` 的 `preview` 不回退基线**，与相邻字段不一致 → completed/error 通知正文可能退化为兜底文案。
- **[P3-2] prefs 关闭审批通知时，resolved(pendingTotal>0) 仍重建 pending 条目** — 当前无视觉危害（红点 UI 在 `unread <= 0` 时整体隐藏），属潜在语义缺口；建议成文"计数是事实记账，与通知偏好无关"。
- **[P3-3] 测试缺口三处**：a) 同帧"显式无计数 + 镜像带计数"的 dedupe 偏好；b) null-taskId 的 resolved 只清 unknown 占位键、保留其他任务键；c) 计数上调（已挂 1 → 新带计数事件写 2）。

## 不变量核对表

| # | 不变量 | 结论 |
| --- | --- | --- |
| 1 | 同任务审批+输入并存：剩 1 不清红点、不撤通知；归零才清 | **PASS** |
| 2 | 缺 summary 行同投递与跨投递都不覆盖基线产生假 resolved | **PASS** |
| 3 | 沿用后，同计数真 summary 行不重复发 permission_request | **PASS** |
| 4 | 旧语义未破坏（removed / unknown 占位 / 显式无计数事件） | **PASS** |
| 5 | dedupe 是否丢带计数的 differ 事件 | **PASS（有界影响，见 P2-1）** |
| 6 | pruneOnSnapshot / 快照替换 / 重连重放基线一致性；粘滞风险 | **PASS（粘滞存在性 UNKNOWN，兜底基本足够，见 P2-3）** |
| 7 | 是否引入新的页面可操纵风险 | **PASS（无新增面；既有负数缺口见 P2-2）** |
| 8 | 可维护性 | **PASS** |

## 亮点

1. `hasPendingSummary` 用"缺省即非权威"的三值语义干净地区分"没带 summary"与"确认无待处理"，同投递/跨投递两条规则各配正反序测试。
2. "计数相同不发状态更新"配了 `identical` 断言，防无意义重建的意图被钉死。
3. ADR-001 如实记录"请求级 id 不可实现"的协议证据与降级决策，含否决候选和复审条件。

---

## 返修状态（主代理记录，2026-09-16）

| 发现 | 处置 | 证据 |
| --- | --- | --- |
| P2-1 dedupe 丢计数 | **已修**：冲突时把后到副本的 `pendingTotal`（及缺失的 sessionTitle）合并进保留副本，文案保留显式版 | `event_parser_test.dart` "dedupe：显式事件在前无计数、differ 副本带计数 → 合并…"、"保留副本已带计数时后到副本不覆盖" |
| P2-2 负数 | **已修**：提取层 `_pendingCount` 只认非负 int | "负数计数按 0 处理且仍算权威；随后 0→1 照常发请求" |
| P2-3 粘滞窗口 | **已成文** ADR-001 已知限制 + 兜底用例 | "权威基线 1 后连续只来扁平行：不发事件…；removed 对账兜底清理" |
| P3-1 preview | **已修** `preview ?? baseline.preview` | "inheritPendingFrom：preview 与交互描述都回退基线" |
| P3-2 通知偏好 | **已成文**（`event_feed.dart` 注释） | — |
| P3-3 测试缺口 | **已补** a/b/c 三条 | `event_parser_test.dart` dedupe 两条；`event_feed_test.dart` "resolved 无 taskId：只清 unknown 占位键…"、"已挂起 1，新到带计数的请求事件写 2" |

返修后：analyze 0，`flutter test` 604/604（E-10）。
