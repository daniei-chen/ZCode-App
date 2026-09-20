# EXECUTION_STATE — ZCode 持续迭代控制视图

> 本文件由 `ITERATION_STATE.json` 渲染；JSON 是唯一机器权威。

- Run: `zcode-app-maturation-2026-09`
- Revision / iteration / phase: `15` / `13` / `RECOVER`
- Status: **CONTINUE**
- Target: `release_candidate` / 85；当前 83
- Checkpoint: `cp-13-iter13` · Git `33b5952d56d3ed87db8e28e6c01f54deda578cdd` · `sha256:62a361b3e199608bdc05bcd1f41efc257e0efc87bb86bb5f291302f9455d77b7`
- Budget: `none` · used `0` / limit `—`

## TERMINATION_CHECKLIST

| Check | Derived |
|---|---|
| T1 | OPEN |
| T2 | OPEN |
| T3 | OPEN |
| T4 | OPEN |
| T5 | OPEN |
| T6 | DONE |
| T7 | OPEN |

## Defects and acceptance

- Open defects P0/P1/P2/P3: `1/0/0/0`
- Acceptance: BLOCKED=7, DEFERRED=0, FAIL=0, NA=0, OPEN=0, PARTIAL=1, PASS=30

## Score

| Dimension | Earned / possible | Ratio | Contribution |
|---|---:|---:|---:|
| core (30) | 23 / 24 | 95.8% | 28.75 |
| security (25) | 18 / 24 | 75.0% | 18.75 |
| tests (20) | 14 / 14 | 100.0% | 20.00 |
| operations (15) | 4 / 12 | 33.3% | 5.00 |
| docs (10) | 9 / 9 | 100.0% | 10.00 |
| **Total** |  |  | **83** |

## Gates

| ID | Required | Status | Checkpoint | Evidence |
|---|---|---|---|---|
| G-001 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-analyze.log |
| G-002 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-test.log |
| G-003 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-js.log |
| G-004 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-docdrift.log |
| G-005 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-secrets.log |
| G-006 | True | BLOCKED | cp-13-iter13 | docs/continuous-iteration/evidence/i11-osv.log |
| G-007 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-script-selftests.log |
| G-008 | False | NOT_RUN | cp-13-iter13 | — |
| G-009 | False | BLOCKED | cp-13-iter13 | — |
| G-010 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-mutations.log |
| G-011 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i13-state.log, docs/continuous-iteration/evidence/i13-mutcov.log |
| G-012 | False | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/b1-build.log |
| G-013 | True | PASS | cp-13-iter13 | docs/continuous-iteration/evidence/i12b-cleanstart.log |

## Audits

| ID | Iteration | Reviewer | Risk | Checkpoint | Coverage | New P0/P1 |
|---|---:|---|---|---|---|---:|
| A-101 | 1 | code-reviewer-iter1-r1 | R2 | cp-1-iter1-pre-repair | DIFF_CORRECTNESS, BOUNDARY_CONTRACT | 0/0 |
| A-102 | 1 | code-reviewer-iter1-r2 | R2 | cp-1-iter1 | DIFF_CORRECTNESS, BOUNDARY_CONTRACT, RESILIENCE | 0/0 |
| A-103 | 2 | code-reviewer-iter2-r1 | R2 | cp-2-iter2-pre-repair | DIFF_CORRECTNESS, BOUNDARY_CONTRACT | 0/0 |
| A-104 | 2 | code-reviewer-iter2-r1（续会话复核返修） | R2 | cp-2-iter2 | DIFF_CORRECTNESS, BOUNDARY_CONTRACT | 0/0 |
| A-105 | 3 | code-reviewer-iter3-r1 | R2 | cp-3-iter3-pre-repair | DIFF_CORRECTNESS, BOUNDARY_CONTRACT, ADVERSARIAL | 0/2 |
| A-106 | 3 | code-reviewer-iter3-r1（续会话复核返修） | R2 | cp-3-iter3 | DIFF_CORRECTNESS, BOUNDARY_CONTRACT, ADVERSARIAL | 0/0 |
| A-107 | 4 | code-reviewer-iter4-r1 | R2 | cp-4-iter4-pre-repair | DIFF_CORRECTNESS, SCALE_DATA | 0/1 |
| A-108 | 4 | code-reviewer-iter4-r1（续会话复核返修） | R2 | cp-4-iter4 | DIFF_CORRECTNESS, SCALE_DATA | 0/0 |
| A-109 | 5 | security-auditor-r3 | R3 | cp-5-iter5-pre-repair | ADVERSARIAL, BOUNDARY_CONTRACT | 0/0 |
| A-110 | 5 | security-auditor-r3（续会话复核返修） | R3 | cp-5-iter5 | ADVERSARIAL, BOUNDARY_CONTRACT | 0/0 |
| A-111 | 6 | code-reviewer-iter6-r1 | R2 | cp-6-iter6-pre-repair | DIFF_CORRECTNESS, BOUNDARY_CONTRACT | 0/1 |
| A-112 | 6 | code-reviewer-iter6-r1（续会话复核返修） | R2 | cp-6-iter6 | DIFF_CORRECTNESS, BOUNDARY_CONTRACT | 0/0 |
| A-113 | 7 | code-reviewer-services-r2 | R2 | cp-7-iter7-pre-repair | RESILIENCE, BOUNDARY_CONTRACT | 0/0 |
| A-114 | 7 | test-engineer-acceptance | R2 | cp-7-iter7 | BOUNDARY_CONTRACT | 0/0 |
| A-115 | 7 | code-reviewer-services-r2（续会话复核返修） | R2 | cp-7-iter7 | RESILIENCE, BOUNDARY_CONTRACT | 0/0 |
| A-116 | 8 | code-reviewer-ui-r2 | R2 | cp-8-iter8-pre-repair | DIFF_CORRECTNESS, RESILIENCE | 0/0 |
| A-117 | 8 | 主代理（修复=审计处方原文 + source-pin/变异机器验证） | R2 | cp-8-iter8 | DIFF_CORRECTNESS | 0/0 |
| A-118 | 9 | 主代理（纯策略+注入式探测，变异 7/7 机器验证；独立复核待下轮 T3） | R2 | cp-9-iter9 | DIFF_CORRECTNESS | 0/0 |
| A-119 | 10 | code-reviewer-iter10-r1 | R2 | cp-10-iter10-pre-repair | DIFF_CORRECTNESS, BOUNDARY_CONTRACT | 0/0 |
| A-120 | 10 | code-reviewer-iter10-r1（最终裁定） | R2 | cp-10-iter10 | DIFF_CORRECTNESS, BOUNDARY_CONTRACT | 0/0 |
| A-121 | 11 | code-reviewer-iter11-r1 | R2 | cp-11-iter11 | DIFF_CORRECTNESS, BOUNDARY_CONTRACT, CLEAN_START_RELEASE | 0/2 |
| A-122 | 11 | code-reviewer-iter11-r1（最终裁定） | R2 | cp-11-iter11 | DIFF_CORRECTNESS, BOUNDARY_CONTRACT, CLEAN_START_RELEASE | 0/0 |
| A-123 | 12 | code-reviewer-iter12-r1 | R2 | cp-12-iter12-pre-repair | RESILIENCE, BOUNDARY_CONTRACT, SCALE_DATA | 0/2 |
| A-124 | 12 | code-reviewer-iter12-r1（最终裁定） | R2 | cp-12-iter12 | RESILIENCE, BOUNDARY_CONTRACT, SCALE_DATA | 0/0 |
| A-125 | 13 | code-reviewer-iter13-r1（dynamic-workflow 零上下文） | R2 | cp-13-iter13-pre-closure | DIFF_CORRECTNESS, BOUNDARY_CONTRACT, SCALE_DATA | 0/0 |

## Candidates

| ID | Severity | Required | Status | Blocker / defer reason |
|---|---|---|---|---|
| W-001 | P1 | True | DONE | — |
| W-002 | P3 | False | DONE | — |
| W-003 | P3 | False | DONE | — |
| W-004 | P3 | False | DONE | — |
| W-005 | P2 | False | DONE | — |
| W-BL1 | P0 | True | BLOCKED | BL-001 |
| W-BL2 | P1 | True | BLOCKED | BL-007 |
| W-BL3 | P2 | True | BLOCKED | BL-004 |
| W-BL4 | P1 | True | BLOCKED | BL-002 |
| W-BL5 | P1 | True | DONE | BL-006 |
| W-BL6 | P1 | True | BLOCKED | BL-003 |
| W-BL7 | P2 | True | BLOCKED | BL-005 |
| W-006 | P3 | False | DONE | — |
| W-007 | P2 | False | DONE | — |
| W-008 | P3 | False | DONE | — |
| W-009 | P2 | False | DONE | — |
| W-010 | P2 | False | DONE | — |
| W-011 | P2 | False | DONE | — |
| W-012 | P3 | False | DONE | — |
| W-013 | P3 | False | DONE | — |
| W-014 | P3 | False | DONE | — |
| W-015 | P3 | False | DONE | — |
| W-016 | P3 | False | DONE | — |
| W-018 | P3 | False | DONE | — |
| W-019 | P3 | False | DONE | — |
| W-020 | P3 | False | DONE | — |
| W-021 | P3 | False | DONE | — |
| W-022 | P3 | False | DONE | — |
| W-023 | P2 | False | DONE | — |
| W-024 | P3 | False | DONE | — |
| W-025 | P2 | False | LOCAL | BL-003 |
| W-026 | P3 | False | DONE | — |
| W-027 | P2 | False | BLOCKED | BL-003 |
| W-028 | P3 | False | BLOCKED | BL-003 |
| W-029 | P2 | False | BLOCKED | BL-001 |
| W-030 | P3 | False | DONE | — |
| W-031 | P2 | False | BLOCKED | BL-004 |

## Blockers

| ID | Type | Required | Status | Recommendation | Unlock |
|---|---|---|---|---|---|
| BL-001 | USER | True | OPEN | 采纳 ADR-003 方案 A（保留现密钥 + 流程加固：密钥只存离线备份与 CI Secrets、审计包永久禁带密钥、定期核验备份），预备 B（离线生成轮换 lineage，不发布） | 用户回复 ADR-003 的三个待决点并记入 docs/DECISIONS.md；涉及密钥材料的步骤必须由用户本机/离线完成 |
| BL-002 | EXTERNAL | True | OPEN | 恢复仓库推送权限后推送 release 分支改动 + 实跑 ci.yml / ci-heavy.yml，累积模拟器 E2E 稳定性证据 | 推送已全部完成（E-47）；余：ci.yml/ci-heavy.yml/release.yml 三工作流在新仓库实跑验证（需仓库 Actions 启用与运行窗口，结果归档 BENCHMARKS-RESULTS） |
| BL-003 | EXTERNAL | True | OPEN | 用户按 docs/RELEASE-CHECKLIST.md 在自有设备执行真机矩阵 + 48h soak + TalkBack/实体生物识别，并把结果归档到 BENCHMARKS-RESULTS | 用户设备与时间窗口可用 |
| BL-004 | USER | True | OPEN | 对 ADR-004 拍板：是否启用每设备独立 WebView 数据目录（隔离收益 vs 多设备常驻成本） | ci.yml/ci-heavy.yml 已在新仓库实跑 success（E-49）；余：release.yml 需签名 Secrets 与分支保护（W-031，用户仓库管理操作） |
| BL-005 | USER | True | OPEN | 对 ADR-005 拍板：无系统锁屏凭据机型是否提供显式知情确认的擦除出口 | 用户对 ADR-005 选项与安全语义作出决定并记入 docs/DECISIONS.md |
| BL-006 | USER | True | RESOLVED | 决定 tag 策略：沿用 v1.0.0（内部 versionCode 递增）或为新线启用新 tag 名（不复用被占用的 v1.0.0） | 用户选择并记入 docs/DECISIONS.md；涉及发布链配置的改动由后续轮次实施 |
| BL-007 | USER | True | OPEN | 真机/soak 期间收集子 frame 导航证据（计数器随诊断包导出），据此在 ADR-002 的 A/B/C 中拍板 | 计数器的运行时数据到位（依赖 BL-003 的设备窗口） |

## Resume

**Next action:** 本地候选清零。待用户：① ADR-003 密钥处置（P0）② ADR-004/005 ③ W-031 release.yml 签名 Secrets+分支保护（新仓库管理配置）④ 真机窗口（W-025/W-027/W-028/BL-003）⑤ iter13 已提交推送（E-49 注记）。

Validation: `valid=true` · derived `CONTINUE` · qualifying audit rounds `[1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13]`.
