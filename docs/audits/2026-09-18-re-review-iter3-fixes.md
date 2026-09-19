# 返修复核：ITERATION 3 批次（W-005 + W-007）

- **日期**：2026-09-18
- **评审方式**：首轮同一 code-reviewer 子代理续会话复核（只读）
- **覆盖标签**：DIFF_CORRECTNESS + BOUNDARY_CONTRACT + ADVERSARIAL
- **前置报告**：`docs/audits/2026-09-18-code-review-iter3.md`（首轮：2×P1 + 3×P2 + 8×P3，需返修后合并）
- **返修后门禁**：`gates.sh i3 --osv` 10 道门全 PASS（state 门首次有执行证据 `i3-state.log`）/ test 635 / 变异 13/13 / 验证器自测 21/21

## 逐项复核

| 项 | 结论 | 要点 |
|---|---|---|
| F-1 验证器夹具误命中 | **PASS** | 跳过 `test_*.py`；单测同时钉住"夹具不报 / 同目录普通 .py 仍报"；D-20260918-02 已登记 |
| F-2 `.gitignore` 忽略 `tools/` | **PASS** | `tools/*` + `!tools/iteration/` 语义正确；期望可见 14 文件与清单一致；D-20260918-03 已登记 |
| F-3 变异语料缺 3 条规则 | **PASS** | 现 10 条，7 规则全覆盖；变异抓到的 OB206 边界缺口已补断言并登记 D-20260918-04 |
| F-4 文档漂移 | **PASS** | MASTER_PLAN:85/108、PROJECT_AUDIT:82 均改为已落地 |
| F-5 证据日志被 `*.log` 忽略 | **PASS（缓解）** | 负规则生效；`--require-tracked` 延后理由成立 → 见 N-1 |
| F-6 DEC-id 前缀误配 | **PASS** | 边界正则 + 单测 |
| F-7 含括号路径截断 | **PASS** | 先试原串 + 单测 |
| F-8 提示词覆盖槽位 | **PASS** | 两份模板均已加 |
| F-9 patch 缺 arb | **FAIL（记账）→ 已修** | 复核时 LESSONS 尚无 L-11；本轮记账已补 L-11..L-16 |
| F-10 mutate.py 健壮性 | **PASS** | read 进 try、重复 id exit 2 |
| F-11 gates.sh 细节 | **PASS** | CANARY 正则收窄（与实际 canary 形态匹配）、`PASS(${PASSED:-0})` |
| F-12 告警语义 | **PARTIAL → 已修** | 注释已修；W-014（分母抗抑制）复核时未落地 → 本轮记账已登记 |
| F-13 键集合护栏 | **PASS** | 11 + 6 = 14 + 3 逐键无遗漏无重叠；变异被抓；`iter3-subframe-wrong-key` 额外触发护栏证明探针真实 |

## 新发现与处置

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| N-1 | P2 | 三处"已登记"声明未落地（W-014、`--require-tracked` 候选、L-11）——引用完整性是本项目核心承诺，而处置说明本身含悬空引用 | **已修**：W-014（P3 分母抗抑制）、W-015（P3 `--require-tracked`）注册进候选池；LESSONS L-11 落地 |
| N-2 | P3 | 新增 `state` 门零执行证据；且门禁先于记账，翻转验收行的批次会让矩阵哈希校验必红 | **已修**：`state` 门默认 WARN、`--strict-state` 致命；检查点终跑用严格模式；README 顺序说明同步；本轮终跑已产出 `i3-state.log`（PASS） |
| N-3 | P3 | README 自测计数/门清单过时 | **已修**：7 + 14；门清单含 state |
| N-4 | P3 | `mutate.py` `decode` 在 try 外；多行 `find` 对 CRLF 敏感 | **已修**：decode 进 try（UnicodeDecodeError）；比对前 LF 归一、写回保持原 EOL |
| N-5 | P3 | 护栏测试对两个分母键的探针是空操作 | **已修**：改为抑制探针（`wsIgnored 20 + wsMessages 100` → 无 OB202；fetch 同理） |
| N-6 | P3 | DEFECTS 引用 A-105/A-106 而状态 JSON 尚无 | **已修**：本轮记账补录 A-105/A-106；W-005/W-007 `review_id` = A-106 |

## 最终结论

**可以合并**（复核原判"需返修后合并——仅记账项"，记账项已全部落地并经 `gates.sh --strict-state` 与 `validate --repo-root .` 机器校验）。
