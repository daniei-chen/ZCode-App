# EXECUTION_STATE — ZCode 持续迭代控制视图

> 本文件由 `ITERATION_STATE.json` 渲染；JSON 是唯一机器权威。

- Run: `zcode-app-maturation-2026-09`
- Revision / iteration / phase: `12` / `11` / `RECOVER`
- Status: **CONTINUE**
- Target: `release_candidate` / 85；当前 80
- Checkpoint: `cp-11-iter11` · Git `16a7d8ee9d1cf084ba6df3c52fcc32633b9fb19b` · `sha256:0d8f79c09409863b6258f4367f119e86b6b82b35073faf7ca1162bc6e7198e4e`
- Budget: `none` · used `0` / limit `—`

## TERMINATION_CHECKLIST

| Check | Derived |
|---|---|
| T1 | OPEN |
| T2 | OPEN |
| T3 | DONE |
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
| operations (15) | 2 / 12 | 16.7% | 2.50 |
| docs (10) | 9 / 9 | 100.0% | 10.00 |
| **Total** |  |  | **80** |

## Gates

| ID | Required | Status | Checkpoint | Evidence |
|---|---|---|---|---|
| G-001 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-analyze.log |
| G-002 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-test.log |
| G-003 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-js.log |
| G-004 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-docdrift.log |
| G-005 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-secrets.log |
| G-006 | True | BLOCKED | cp-11-iter11 | docs/continuous-iteration/evidence/i11-osv.log |
| G-007 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-script-selftests.log |
| G-008 | False | NOT_RUN | cp-11-iter11 | — |
| G-009 | False | BLOCKED | cp-11-iter11 | — |
| G-010 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-mutations.log |
| G-011 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11-state.log, docs/continuous-iteration/evidence/i11-mutcov.log |
| G-012 | False | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/b1-build.log |
| G-013 | True | PASS | cp-11-iter11 | docs/continuous-iteration/evidence/i11b-cleanstart.log, docs/continuous-iteration/evidence/i11neg-cleanstart.log |

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
| W-BL5 | P1 | True | BLOCKED | BL-006 |
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
| W-015 | P3 | False | LOCAL | — |
| W-016 | P3 | False | DONE | — |
| W-018 | P3 | False | LOCAL | — |
| W-019 | P3 | False | DONE | — |
| W-020 | P3 | False | DONE | — |
| W-021 | P3 | False | LOCAL | — |
| W-022 | P3 | False | DONE | — |
| W-023 | P2 | False | DONE | — |
| W-024 | P3 | False | DONE | — |

## Blockers

| ID | Type | Required | Status | Recommendation | Unlock |
|---|---|---|---|---|---|
| BL-001 | USER | True | OPEN | 采纳 ADR-003 方案 A（保留现密钥 + 流程加固：密钥只存离线备份与 CI Secrets、审计包永久禁带密钥、定期核验备份），预备 B（离线生成轮换 lineage，不发布） | 用户回复 ADR-003 的三个待决点并记入 docs/DECISIONS.md；涉及密钥材料的步骤必须由用户本机/离线完成 |
| BL-002 | EXTERNAL | True | OPEN | 恢复仓库推送权限后推送 release 分支改动 + 实跑 ci.yml / ci-heavy.yml，累积模拟器 E2E 稳定性证据 | GitHub 账号可用（推送与 Actions 运行权限） |
| BL-003 | EXTERNAL | True | OPEN | 用户按 docs/RELEASE-CHECKLIST.md 在自有设备执行真机矩阵 + 48h soak + TalkBack/实体生物识别，并把结果归档到 BENCHMARKS-RESULTS | 用户设备与时间窗口可用 |
| BL-004 | USER | True | OPEN | 对 ADR-004 拍板：是否启用每设备独立 WebView 数据目录（隔离收益 vs 多设备常驻成本） | 用户对 ADR-004 选项与代价作出决定并记入 docs/DECISIONS.md |
| BL-005 | USER | True | OPEN | 对 ADR-005 拍板：无系统锁屏凭据机型是否提供显式知情确认的擦除出口 | 用户对 ADR-005 选项与安全语义作出决定并记入 docs/DECISIONS.md |
| BL-006 | USER | True | OPEN | 决定 tag 策略：沿用 v1.0.0（内部 versionCode 递增）或为新线启用新 tag 名（不复用被占用的 v1.0.0） | 用户选择并记入 docs/DECISIONS.md；涉及发布链配置的改动由后续轮次实施 |
| BL-007 | USER | True | OPEN | 真机/soak 期间收集子 frame 导航证据（计数器随诊断包导出），据此在 ADR-002 的 A/B/C 中拍板 | 计数器的运行时数据到位（依赖 BL-003 的设备窗口） |

## Resume

**Next action:** ITERATION 12：余量候选 W-015（require-tracked，待首次提交后启用）/W-018（widget 测试+诊断包暴露隔离计数）/W-021（卫生打包）；本地清零后转 BLOCKED。待用户：ADR-003（P0）/004/005、GitHub 账号（G-006/G-009）、真机窗口（B8/C2b/BL-003）。

Validation: `valid=true` · derived `CONTINUE` · qualifying audit rounds `[1, 2, 3, 4, 5, 6, 7, 8, 10, 11]`.
