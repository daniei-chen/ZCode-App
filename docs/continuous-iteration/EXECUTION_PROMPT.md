# 持续迭代 ZCode App：本 ZCode Goal 回合只完成一个有界批次

仓库：`D:\AI\zcode\ZCode App`
控制目录：`D:\AI\zcode\ZCode App\docs\continuous-iteration`
状态文件：`D:\AI\zcode\ZCode App\docs\continuous-iteration\ITERATION_STATE.json`
技能目录：`C:\Users\Administrator\.zcode\skills\continuous-iteration-plan`
校验命令：`python C:\Users\Administrator\.zcode\skills\continuous-iteration-plan\scripts\iteration_state.py validate "D:\AI\zcode\ZCode App\docs\continuous-iteration\ITERATION_STATE.json"`
目标档位：release_candidate（85）· 预算：无（kind=none）· 目标运行：`run_id = zcode-app-maturation-2026-09`

授权边界（未列出即未授权）：
- 允许：本地代码编辑、在**临时导出目录**跑 analyze/test/构建（见 DEC-02/DEC-14）、`flutter pub get`、只读公网查询（OSV 等官方数据）、写 `docs/` 台账与本控制目录、读全部仓库文件。
- 禁止（需用户明确授权，否则登记 blocker）：提交/推送/合并/改写 Git 历史（当前 DEC-06：不提交，除非用户改口）、部署/DNS、付费资源、发送外部消息/webhook、接触密钥材料（签名密钥仅用户本机离线操作）、真实用户数据、删除数据、改公开契约或产品方向（ADR-004/005 等属用户拍板项）。

提交策略：不提交、不推送（DEC-06）；每轮结束报告 `git status --short` 与代码域 diff 指纹。

## 关键语义

这是 ZCode Goal Mode 的一轮。完成一个完整批次后必须落盘并结束本轮，让 ZCode 独立校验器判断：CONTINUE 会自动开下一轮；TERMINATED/BLOCKED/BUDGET 才是目标级终态。不要在同一回合偷偷开启第二批，也不要问"要不要继续"。

状态 JSON 是循环权威；Markdown 视图不是。完成声明必须有当前代码检查点的文件、命令输出、测试或审计证据。计划、待办、运行时长和自我评价不算完成。

**检查点口径**：`checkpoint.diff_fingerprint` = `git diff HEAD -- lib test android scripts pubspec.yaml pubspec.lock .github integration_test tools` 的 sha256（代码域）；纯 `docs/` 台账编辑不改变代码检查点，但台账事实变化必须同步 `revision` 与 artifact 状态。

## 八阶段

1. RECOVER：按 `ITERATION_STATE.json` → `source_map`（DEFECTS/ACCEPTANCE_MATRIX/EVIDENCE/DECISIONS → audits/）→ `git status/diff --stat` 顺序读取。若代码指纹漂移，使受影响门禁与审计失效。
2. PLAN：从 LOCAL 候选按 P0/P1、关键验收、风险与依赖选 1–3 个同主题项；写验收点、门禁、风险级别与预计资源。没有 LOCAL 才检查阻塞/终止。
3. IMPLEMENT：最小一致改动。P0/P1 配回归测试；契约、迁移、权限、状态机、用户文档同步。不得执行未授权动作。
4. GATE：跑下表必需门禁；PASS/FAIL/BLOCKED/NOT_RUN 分开，记录命令、退出码、环境和证据路径（写 `docs/continuous-iteration/evidence/`）。基线本来红不代表本轮通过。
5. AUDIT：按 R0–R3 派独立子智能体（覆盖标签见下）。提示词自包含、禁止修改、不携带主 Agent 的完成结论；记录 reviewer_id、checkpoint_id、coverage 与报告到 `docs/audits/`，并在状态 JSON `audits[]` 登记。
6. REPAIR：审计发现进 `docs/DEFECTS.md`；复现、修复、回归，并由不同审阅者复核当前检查点。代码变更后旧审计不得继续证明 T3。
7. CHECKPOINT：更新事实台账、证据、代码指纹、计分历史、候选、artifact revision、blocker 与 `resume.next_action`。主 Agent 是唯一状态写入者。
8. DECIDE：`sync`（原子推导 status/claim/checks）→ `validate` → `render --output docs/continuous-iteration/EXECUTION_STATE.md`。输出轮次报告（格式见下）并结束本轮。

## 门禁清单（当前检查点 `cp-0-baseline` 全部 PASS）

| ID | 命令 | 必需 | 说明 |
| --- | --- | --- | --- |
| G-001 | `flutter analyze`（临时导出；先同步工作区改动） | 是 | 0 issues |
| G-002 | `flutter test` 全量（同上导出） | 是 | 当前 605/605；新增用例后计数递增 |
| G-003 | `node scripts/check_injected_js.mjs` | 是 | 49/49 |
| G-004 | `python scripts/check-doc-drift.py` | 是 | 6/6 |
| G-005 | 秘密扫描（ls-files 扩展名 + git grep 字面量 + check-ignore） | 是 | 0 命中 |
| G-006 | `python scripts/check-dependency-advisories.py --sbom <b5 SBOM> --exceptions scripts/security-exceptions.json --fail-on high` | 是 | 依赖面变化时必跑；未变可复用 E-17 结论并注明 |
| G-007 | 发布脚本自测 5 件套（doc-drift/advisories/plugin/artifacts/sbom `--self-test`） | 是 | 87/87 |
| G-008 | 出包链：`flutter build apk --release` + 插件存活门 + `verify-release-artifacts` | 否 | 涉及发布/原生改动时启用（先构建后测试，见 PLAN 操作注意） |
| G-009 | GitHub Actions 三工作流真实实跑 | 否 | 外部阻塞 BL-002 |

审计风险级别：R0 文档/台账（状态校验+链接/占位符）；R1 局部低风险（1 次聚焦 diff 审计）；R2 行为/契约（每轮 1 个独立审阅者覆盖当前检查点）；R3 认证/秘密/迁移/删除/生产/外部副作用（至少 2 个不同审计视角；外包动作另需授权）。覆盖标签从 DIFF_CORRECTNESS / BOUNDARY_CONTRACT / ADVERSARIAL / RESILIENCE / SCALE_DATA / CLEAN_START_RELEASE 中按轮次升级或轮换；连续清洁轮次不得只重复同一提示词与同一路径。

## 决策边界（四门测试）

只有同时满足"可本地完整回滚、无外部副作用、无费用、不接触秘密/生产/真实数据、不改公开契约或产品方向"的决定才可 provisional 推进。数据删除/不可逆迁移、API/协议兼容、身份权限、安全策略、密钥与证书、计费、生产/DNS、外部消息、真实用户数据、许可证/隐私、付费资源、发布/合并/改写历史、重大产品方向——一律需要既有明确授权；没有就登记 blocker 并转做其他候选。

## 终态

- TERMINATED：`validate` 成功且 T1–T7 全 DONE（T1 无 open P0/P1；T2 无 OPEN/PARTIAL/FAIL/BLOCKED 验收；T3 连续两个不同轮次独立清洁审计且最新覆盖当前检查点、有覆盖升级；T4 分数≥85 且各维度达下限、最近两轮稳定；T5 必需门禁当前检查点全 PASS；T6 artifact 与 revision 一致、无占位符、秘密扫描 PASS；T7 无 LOCAL、无目标必需 BLOCKED、延期合规）。
- BLOCKED：无 LOCAL，至少一个目标必需项需用户/外部解锁；列推荐项、风险与解锁条件。
- BUDGET：仅当状态文件记录了用户预算且耗尽；当前无预算，不适用。
- 其他一律 CONTINUE。工具瞬时失败、限流、上下文压缩和 ZCode 轮次结束都不是 BLOCKED。

## 流程工具链（RSI-0 起强制使用）

- 门禁：`bash tools/iteration/gates.sh <prefix> --osv`（导出目录一键 9 道门，含状态机 --repo-root 校验，证据自动落 `evidence/<prefix>-*.log`）。
- 变异验证：`python tools/iteration/mutate.py --export /d/tmp/zr/ci_<prefix> --spec tools/iteration/mutations/*.json --require-green`（每个新测试必须有一条语料）。
- 状态机：`python tools/iteration/iteration_state.py {validate|sync|render} --repo-root . ...`（--repo-root 校验引用/哈希/缺陷号/review_id）。
- 审计：`tools/iteration/prompts/{review-r2,security-r3,acceptance-te}.md` 模板；覆盖标签阶梯与八小时纲领见 `EXECUTION_PROGRAM_8H.md`；教训回灌 `LESSONS.md`。

## 本轮候选池（LOCAL，按优先级）

已完成：W-001（C2a 子 frame 取证计数器，iter1）、W-002（D-15 notifier 异常围栏，iter1）、W-003（D-10 dedupe 键去 summary，iter2）、W-006（D-20260917-01 route 取 path，iter2，随批 D-20260918-01）。

1. **W-005（P2）观察面变化自动告警**：sseIgnored / 未命中计数阈值 → 诊断页提示（MASTER_PLAN 下一阶段）。只做本地可验证部分：阈值判定纯函数 + 诊断页行 + 测试；不引入网络与新权限。
2. W-004（P3）A-12：BENCHMARKS-RESULTS 模拟数据持续可见标注复核（文档为主）。

BLOCKED（需用户/外部，见状态 JSON `blockers`）：BL-001 密钥处置（P0，T1/T2）、BL-002 GitHub 账号、BL-003 真机矩阵、BL-004/005 ADR-004/005 拍板、BL-006 tag 策略、BL-007 子 frame 运行时证据。G-006 OSV 需公网 DNS（当前解析到 198.18.0.150）。

下一轮唯一动作（`resume.next_action`）：实施 W-005（+W-004 若批次余量允许）→ 同步导出 → G-001..G-007 → R2 独立审计（DIFF_CORRECTNESS+BOUNDARY_CONTRACT）→ 记账；网络恢复后重跑 G-006。

## 报告格式

第一行保持机器可扫读：

```text
ITERATION <n> | STATUS: CONTINUE|BLOCKED|TERMINATED|BUDGET | SCORE: <prev>→<current> | OPEN P0/P1: <p0>/<p1> | NEXT: <one action>
```

随后只写：本轮变更；门禁与证据；审计与返修；台账变化；阻塞/延期及依据；下一动作。STATUS=CONTINUE 时明确写"目标未完成"，确保 ZCode 校验器开启下一轮。
