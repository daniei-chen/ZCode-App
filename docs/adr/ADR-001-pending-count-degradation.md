# ADR-001 待处理交互记账按"任务权威剩余计数"降级（R-19）

- 状态：**已采纳**（2026-09-16，本轮实施）
- 关联：审计项 R-19（原要求 pending 按 `(taskId, requestId)`）、缺陷 D-20260916-01/02、F11（前序：设备级布尔 → 任务集合）

## 背景

审计 R-19 要求把待处理交互按 `(taskId, requestId)` 记账，并注明"若上游无 ID，降级方案必须成文"。核实上游观察面（`docs/RELAY-PROTOCOL-VERIFIED.md` + 真实夹具 `test/event_parser_test.dart`）：

- 会话镜像携带 `pendingInteractionSummary { permissionCount, userInputCount }`——**按任务聚合的计数**；
- `pendingInteraction.interactionId` 只标识**当前浮出的一条**交互，无法枚举其余挂起项；
- `controller/tasks-index` 的任务行**天然不带** summary，且与镜像一起进入 `StateDiffer`。

结论：请求级 id 在可观察面上不存在，`(taskId, requestId)` 不可实现。

## 候选

| 方案 | 说明 | 否决理由 |
| --- | --- | --- |
| A 请求级键 `(taskId, requestId)` | 审计原方案 | 上游无可枚举的请求 id |
| B 任务集合（现状） | 任务在集合内即红点 | 同任务两条交互解决一条即清红点；扁平行 0 冒充"已解决" |
| **C 任务权威剩余计数** | `pendingByTask[taskId] = permission + userInput`；`resolved` 携带剩余量；缺 summary = 未知而非 0 | — |

## 决定

采纳 C：

1. `ObservedEvent.pendingTotal`：differ 在 request/resolved 事件上携带转移后的权威剩余量；`removed` 路径为 null（观察面给不出）。
2. `event_feed`：请求事件有计数直接采信、无计数只保证在场；`resolved` 有正计数直接写入并保留红点，null/0 走旧的逐键清理。
3. `webview_sync`：`resolved` 仅在剩余 ≤ 0 时撤系统通知。
4. `SessionState.hasPendingSummary`：同一投递内缺 summary 的副本不覆盖带 summary 的；跨投递缺 summary 的行沿用基线计数（`inheritPendingFrom`），沿用副本标记权威，避免下一条同计数镜像重复发请求。

## 验证

- `test/event_feed_test.dart` "R-19 同任务多条交互按计数记账"组（6 用例）；
- `test/event_parser_test.dart` "R-19 事件携带剩余交互计数"（5）、"同一投递内重复副本合并"（4）、"跨投递：缺 summary 的行沿用基线计数"（5）；
- 全量 594/594、analyze 0（`docs/EVIDENCE.md` E-05）。

## 后果与已知限制

- 红点/系统通知语义与真实剩余量一致；1 条 → 0 条与 2 条 → 1 条可区分。
- **已知限制 1**：计数 1→2（新请求叠加在已挂起任务上）不再由 differ 触发提醒，依赖页面显式事件补位（D-20260916-03）。是否改为"计数增加即提醒"需评估重连重放导致重复通知的风险，留待产品确认。
- **已知限制 2（粘滞窗口，复审 P2-3）**：跨投递沿用基线后，权威计数的归零出口只有两个——带 summary 的会话镜像/任务行，或 removed/archived 对账。若某 workspace 的 sessions-index 增量从此不再到达而只剩任务索引扁平行，该任务红点会持续到 removed、镜像重现或应用重启（feed 为内存态）。该场景在现有协议证据下**存在性未证实**（resolved 通常伴随 sessions-index 增量到达）；硬兜底"连续 N 次 inherit 后降级为非权威"会引入误清风险，不在本轮实施，待产品确认。兜底出口由测试钉住："权威基线 1 后连续只来扁平行…；removed 对账兜底清理"。
- 系统通知在部分解决后保留，但其文案是首条请求的摘要，可能与剩余那条不一致（红点与浮窗卡为主要面，可接受）。
- **复审加固（2026-09-16）**：观察面数值来自页面内容，提取层只认非负 int 且封顶 `kMaxPendingCount = 1024`（防 `1e999`→Infinity 抛异常中断整帧、防负数吞掉转移、防求和回绕）；时间戳只认有限值；`ingestMessage` 外层兜底 try/catch 走 BR202 留痕；`EventParser.dedupe` 冲突时把 differ 副本的权威计数合并进保留的显式事件。

## 回退与复审

- 回退：恢复 `Set<String>` 记账即回到 B（不建议）。
- 复审条件：上游提供全部挂起交互列表（含 id）时，升级为方案 A。
