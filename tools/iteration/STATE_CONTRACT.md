# `ITERATION_STATE.json` 契约

仅在初始化、修复或校验循环状态时读取本文件。机器权威是 JSON；`EXECUTION_STATE.md` 只是渲染视图。

## 1. 顶层字段

| 字段 | 含义 |
|---|---|
| `schema_version` | 当前为 `3.0` |
| `run_id` | 本次持续迭代的稳定标识，续跑时不变 |
| `revision` | 每次原子状态更新递增 |
| `iteration` | 已进入的 ZCode Goal 轮次号，基线为 0 |
| `phase` | `RECOVER/PLAN/IMPLEMENT/GATE/AUDIT/REPAIR/CHECKPOINT/DECIDE` |
| `status` | 声明状态；必须等于校验器推导值 |
| `target` | 目标档位、目标总分和维度下限 |
| `budget` | 用户预算；没有就用 `kind: none` |
| `checkpoint` | 当前代码检查点 ID、Git HEAD、diff 指纹和时间 |
| `source_map` | 缺陷、验收、证据、决策、审计等事实的权威路径 |
| `defects` | 各严重度仍开放数量 |
| `acceptance` | 各验收状态数量；BLOCKED 仍是未完成 |
| `score` | 五维原始权重点与历史快照 |
| `gates` | 必需/可选门禁、状态、检查点和证据 |
| `audits` | 独立审计身份、轮次、检查点、覆盖和发现 |
| `candidates` | 本地、阻塞、延期或完成的工作项 |
| `blockers` | 外部/用户阻塞及解锁条件 |
| `artifacts` | 需要与当前修订同步的文档/台账 |
| `hygiene` | 占位符数量与秘密扫描状态 |
| `termination` | T1–T7 声明和理由；由脚本复算 |
| `resume` | 下一轮唯一动作 |
| `change_log` | 权重、适用性、严重度、拆分合并等治理变更 |

使用 [../assets/ITERATION_STATE.template.json](../assets/ITERATION_STATE.template.json) 初始化，不要凭记忆重造字段。

## 2. 目标档位

| `level` | 总分 | 核心 | 安全 | 测试证据 | 运维恢复 | 文档交接 |
|---|---:|---:|---:|---:|---:|---:|
| `prototype` | 55 | 50% | 40% | 40% | 25% | 25% |
| `internal_beta` | 70 | 65% | 60% | 60% | 50% | 50% |
| `release_candidate` | 85 | 80% | 80% | 75% | 70% | 70% |
| `production_improvement` | 95 | 90% | 90% | 85% | 85% | 80% |

总分权重：核心 30、安全隐私 25、测试证据 20、运维恢复 15、文档交接 10。每维贡献为 `维度权重 × earned / possible`；`possible` 为基线冻结后的适用验收权重，`earned` 只来自 PASS 和允许的 PARTIAL 折算。BLOCKED/OPEN/FAIL 贡献 0，不从 `possible` 中删除。

状态文件只保存每维 `earned` 与 `possible`。验收台账保存条目级权重和证据；每次计分都在 `history` 写轮次、总分和验收源文件哈希。校验器复算总分并检查最后历史行。

T4 要求：至少有基线加两个完成轮次；最近两个完成轮次都达到目标；最新分数不低于前一轮；所有维度达到档位下限。分数高但某个关键维度空心，不能终止。

## 3. 验收状态

- `PASS`：当前检查点有直接证据。
- `PARTIAL`：只满足一部分，终止时视为未完成。
- `OPEN`：尚未验证或尚未实现。
- `FAIL`：已验证失败。
- `BLOCKED`：目标必需，但需外部/用户解锁；仍计入分母并阻止 TERMINATED。
- `DEFERRED`：不属于当前目标成熟度，且满足延期规则。
- `NA`：确实不适用；原则上只在基线冻结前设置。

计数与权威验收台账不一致时，先修复计数和哈希，不能只改状态声明。

## 4. 门禁

门禁对象：

```json
{
  "id": "G-001",
  "command": "pnpm test",
  "required": true,
  "status": "PASS",
  "checkpoint_id": "cp-3",
  "evidence": ["docs/continuous-iteration/evidence/g-001.txt"]
}
```

`required: true` 的门禁只有 `PASS` 且 `checkpoint_id` 等于当前检查点才计入 T5。`NOT_RUN`、`FAIL`、`BLOCKED` 均不通过。若代码在门禁后变化，更新检查点会自动让旧 PASS 失效。

## 5. 审计

审计对象至少包含：

```json
{
  "id": "A-003",
  "iteration": 3,
  "reviewer_id": "zcode-subagent-reviewer-3",
  "independent": true,
  "risk": "R2",
  "checkpoint_id": "cp-3",
  "coverage": ["DIFF_CORRECTNESS", "RESILIENCE"],
  "new_p0": 0,
  "new_p1": 0,
  "report": "docs/continuous-iteration/audits/A-003.md"
}
```

T3 取最近两个不同轮次的合格审计：必须独立、审阅者不同、无新增 P0/P1、有报告；最新一轮覆盖当前检查点；两轮覆盖集合不能完全相同。R3 本轮至少有两个不同审阅者，但连续清洁轮次仍按轮次计，不按审计数量凑数。

## 6. 候选与阻塞

候选 `status` 只允许 `LOCAL/BLOCKED/DEFERRED/DONE`。

- `LOCAL` 是 ZCode 下一轮可以推进的项目；存在 LOCAL 时不能 BLOCKED 或 TERMINATED。
- `BLOCKED` 必须有 `blocker_id`，对应 OPEN blocker。
- `DEFERRED` 的 `required_for_target` 必须为 false，且需要 `defer_reason` 与覆盖当前 checkpoint 的独立 `review_id`；P2 还需要 `approval_ref`，P0/P1 禁止延期。验收表中的 DEFERRED 数不能超过状态中可核对的延期候选数。
- `DONE` 必须在权威台账有当前检查点证据，状态 JSON 只做索引。

blocker 只允许 `USER` 或 `EXTERNAL` 类型，至少写推荐项、解锁条件、证据和受影响的 `blocks: [Tn...]`。BLOCKED 验收必须有对应阻塞候选。代理限流、一次命令失败或本轮时间不够不是 blocker。

## 7. T1–T7 推导

| 检查 | DONE 条件 |
|---|---|
| T1 | open P0/P1 均为 0 |
| T2 | 验收 OPEN/PARTIAL/FAIL/BLOCKED 均为 0 |
| T3 | 最近两个不同轮次的独立清洁审计合格，最新覆盖当前检查点，覆盖有升级/轮换 |
| T4 | 分数和维度下限达标，最近两个完成轮次稳定 |
| T5 | 所有必需门禁在当前检查点 PASS |
| T6 | 必需 artifact 与当前 revision 一致且有证据；无模板标记/占位符；秘密扫描 PASS 且有证据 |
| T7 | 无 LOCAL、无 BLOCKED 候选；所有 DEFERRED 合规 |

若条件不满足且存在真实外部阻塞、且没有 LOCAL，相关检查可推导为 BLOCKED；否则为 OPEN。

最终状态按顺序推导：

1. T1–T7 全 DONE → `TERMINATED`。
2. 用户预算已耗尽 → `BUDGET`。
3. 没有 LOCAL，存在目标必需 blocker 或 BLOCKED 候选/验收/门禁 → `BLOCKED`。
4. 其他 → `CONTINUE`。

状态文件的 `status`、`termination.claim` 和 `termination.checks` 必须与推导完全一致。校验失败时保持项目未完成；修复状态，而不是放宽校验器。

## 8. 原子更新

编辑状态时先写临时文件、运行校验，再替换正式文件；若工具不支持原子替换，至少保留上一个有效副本。更新顺序：事实台账与证据 → 代码检查点 → 状态计数/分数 → 终态推导 → Markdown 视图。

不要让多个可写子智能体同时编辑同一状态文件。主 Agent 是唯一状态写入者；审计子智能体只返回报告。
