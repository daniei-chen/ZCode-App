# 零上下文复审报告 — R-19 返修批（2026-09-16）

> 复审代理：code-reviewer（零历史、只读；与首轮评审不同的新代理）。范围：首轮评审后主代理的返修六项（值域/有限性辅助、dedupe 合并、`inheritPendingFrom` preview、`ingestMessage` 兜底、feed 注释、新增测试）。
> 结论：**可以合并**——返修六项全部属实且实现正确；A–H 八项核对全 PASS；无 P0/P1/P2，4 条 P3。

## 问题清单（均 P3）

| # | 问题 | 处置（主代理） |
| --- | --- | --- |
| P3-1 | dedupe 合并中 `sessionTitle`"保留副本优先"方向无测试钉住（现有夹具两种方向都通过） | **已补**用例"保留副本已有标题时不被后到副本覆盖" |
| P3-2 | `hasFlatCount` 注释写"任一存在即算权威"，实现是"合法非负 int 存在才算" | **已改**注释措辞 |
| P3-3 | `bridgeMessageDropped` 兜底日志在持续性 bug 下可刷穿 500 行环形缓冲 | **已加节流**：首次 + 每 50 次，附累计数（`LogField.count`） |
| P3-4 | `notifier.dart` `notifyFrom` 内 `NotificationSpec.from` 位于内部 try 之外，`unawaited` 异步异常不受 `ingestMessage` 兜底覆盖（既有形态，非本轮引入；纯格式化，风险低） | **登记 D-20260916-15**，超出本批文件范围，留下一批 |

## A–H 核对

| 项 | 结论 | 要点 |
| --- | --- | --- |
| A `_pendingCount` 拒绝 double 是否误伤 | PASS | 生产入口 `jsonDecode` 整数字面量→int；桌面端 Electron `JSON.stringify` 对整值只输出 `2`；全部夹具整数字面量。若上游改用会输出 `2.0` 的序列化器会静默归 0——当前架构下不成立 |
| B `countFromMaps` 首个合法优先 vs 原首个 num | PASS | 正常数据逐容器等价；早位容器持非法 num 时新实现跳过取后位合法值或 0，严格更安全 |
| C 扁平负数 → 非权威 → 沿用基线 | PASS | fail-safe 方向：损坏负值不可能产生假 resolved；最坏红点滞留，有 removed/prune 兜底。已知不对称：summary 对象内负数仍算权威（归 0），两方向都安全 |
| D dedupe 下标映射 / 标题方向 / 文案 | PASS | 原位替换 + 稳定下标；保留副本优先；被合并 differ 副本的 summary 丢失由 `webview_sync` 的 session 回填补齐 |
| E try/catch 吞编程错误 / `unawaited` 范围 | PASS（附 P3-3/4） | 单帧独立推导，丢帧不污染状态；修复前是插件 handler 的 unhandled error，严格更差；`unawaited` 确认在 try 之外，内部 try 已覆盖插件错误 |
| F 时间戳 `_finiteInt` 与原实现一致性 | PASS | 有限 double 逐值一致；仅 ±Infinity/NaN 由抛异常变 null；`toInt()` 全库只剩 `_finiteInt` 内部一处 |
| G 新测试"回退即失败" | PASS | 10 条逐条给出失败机制；无只测 happy path |
| H 未使用导入 / 死代码 / 风格 | PASS | 新导入均被使用；无死代码；仅 P3-2 措辞漂移 |

## 亮点

1. 值域收口集中：所有计数/时间戳站点经三个单一入口，无旁路。
2. dedupe"原位替换 + 稳定下标"，多次合并不破坏映射，绝不动保留副本文案。
3. 新测试每条有明确"回退即失败"机制；粘滞窗口与 removed 兜底同一用例钉住。

---

P3-1～3 修复后：analyze 0，`flutter test` **605/605**（E-15）。
