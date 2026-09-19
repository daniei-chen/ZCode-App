# 零上下文复审报告 — ITERATION 1 返修批（2026-09-17）

> 复审代理：code-reviewer（零历史、只读；与首轮审计不同的新代理）。范围：F-1～F-4 返修 + F-5 登记核验。
> 结论：**可以合并**——A–E 五项返修声明全部属实且实现正确（5/5 PASS），未发现阻塞性新问题；3 条新 P3（N-1/N-2/N-3，当场修复）+ 1 条待确认（N-4，首轮审计文件漏落盘，已由主 Agent 补齐）。

## A–E 逐项核对

| 项 | 结论 | 要点 |
| --- | --- | --- |
| A（F-1）mounted 守卫 + 决策无条件返回 | PASS | record() 包 `if (mounted)`，return 在守卫外无条件执行；放行/拦截不依赖 State 存活，无 ref 越过 dispose 崩溃路径 |
| B（F-2）spec/show 分离留痕 | PASS | 独立 try 记 reason='spec' 后直接 return；spec==null 提前返回在 try 外，不误记 NT501；show 段 reason='show'；测试断言 `completes` + `NT501` + `reason=spec`，回退即失败成立 |
| C（F-3）merge 纯函数 + 接入 + 测试 | PASS | 并集合并、`...?` 单侧缺设备、三用例精确 map 相等断言；bundle 类型匹配 DiagnosticsInputs.stats |
| D（F-4）擦除覆盖 subFrameStats | PASS | 清单含键 + run() 实际 clear()；主用例"预置→擦除→断言空"行为级验证；containsAll 锁清单条目 |
| E（F-5）登记不修 | PASS | uri?.toString() 经 LogRedactor.route 统一去 query/fragment，无凭证泄漏；登记为注释缺陷恰当 |

## 复审新发现（均 P3，当场修复）

- **[N-1][P3]** subFrame 三键与 BridgeSchema.statsKeys 白名单不相交仅靠注释声明，无测试锁定——未来白名单加入同名键会被原生值静默覆盖。修复：测试断言交集为空。
- **[N-2][P3]** protected_wipe 测试"清单与实际 clear() 一一对应"注释强于断言本身（循环体只查名称格式）。修复：修正注释指向主用例。
- **[N-3][P3]** subframe_stats merge 注释"诊断页渲染与诊断包导出必须共用这一份合并结果"与实际不符（页面渲染仍分别遍历两个 provider）。修复：注释改为"内容须与诊断页渲染保持等价"。
- **[N-4][待确认]** 首轮审计文件在工作树缺失——主 Agent 补落 docs/audits/2026-09-17-code-review-iter1.md 与本文件，返修标记（"iter1 复审 F-x"注释）恢复可追溯。

## 亮点

1. F-1 注释明确记录"决策无条件返回、计数只在挂载时记"的语义边界。
2. F-2 测试用只抛一个 getter 的 l10n 桩精准命中 bodyFor 兜底分支，断言同时覆盖不外溢与 reason 区分度。
3. F-4 采用"预置 → 擦除 → 断言空"的完整事务路径验证，而非只查清单字符串。

## 覆盖

实际读过：docs/audits/ 目录、official_remote_page（全文）、notifier（全文）、subframe_stats（全文）、observer_stats、protected_wipe、diagnostics_page、diagnostics_bundle、bridge_schema（statsKeys 段）、structured_log（LogRedactor 段）、app_log（_normalize 段）、subframe_stats_test / protected_wipe_test / notifier_test（全文）。
