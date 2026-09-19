# 代码评审：ITERATION 3 批次（W-005 观察面告警 + W-007 流程工具链）

- **日期**：2026-09-18
- **评审方式**：零上下文 code-reviewer 子代理（只读；提示词 `tools/iteration/prompts/review-r2.md` 实例化）
- **覆盖标签**：DIFF_CORRECTNESS + BOUNDARY_CONTRACT + **ADVERSARIAL**（较 iter2 升级）
- **评审对象**：`D:\tmp\zr\iter3_batch.patch`（W-005，对 RSI-0 基线导出）+ `tools/iteration/` 全部文件（W-007）
- **门禁（评审前）**：`gates.sh i3 --osv` analyze 0 / test 634 / JS 49 / doc-drift 6 / 秘密 0 / 自测 87 / OSV BLOCKED；变异 9/9；验证器自测 18/18

## 结论

**需返修后合并**（2×P1 + 3×P2 + 8×P3）。W-005 的 Dart 部分（策略/页面/诊断包/测试/PRIVACY）无 P0–P2；两个 P1 都落在 W-007 工具链上。

## 发现与处置

| # | 级别 | 位置 | 问题 | 处置 |
|---|---|---|---|---|
| F-1 | **P1** | `iteration_state.py` 缺陷号扫描 | 扫描 `tools/**/*.py` 命中自身测试夹具的合成缺陷号 `D-20260101-01`/`D-20260202-02` → 真实仓库根 `validate --repo-root .` 必然 exit 1；我此前的"exit 0"是在写测试文件之前跑的，绿灯依赖于时序 | **已修**：跳过 `test_*.py`；新增单测；真实仓库根重跑 `valid=true`；登记 D-20260918-02 |
| F-2 | **P1** | `.gitignore:58` `tools/` | 整目录忽略 → 工具链根本未入仓（`git ls-files tools` = 0），gates.sh 导出覆盖也永远拿不到它 | **已修**：`tools/*` + `!tools/iteration/`；14 文件可见；登记 D-20260918-03 |
| F-3 | P2 | `mutations/iter3.json` | 7 条规则只有 6 条语料，OB203/OB205/OB206 无变异 | **已修**：补 3 条 + 键集合护栏 1 条；**变异工具随即抓到 OB206 边界值 1 未测（`<= 1` 存活）**→ 补断言；登记 D-20260918-04 |
| F-4 | P2 | `PROJECT_MASTER_PLAN.md:85,108`、`PROJECT_AUDIT.md:82` | 仍写"观察面告警（下一阶段）/无自动告警" | **已修** |
| F-5 | P2（待确认） | `.gitignore:3` `*.log` | 证据日志被全局忽略，`check_repo_links` 只证明本机存在 | **已修**：`!docs/continuous-iteration/evidence/*.log`；`--require-tracked` 记候选（DEC-06 阶段恒 FAIL，无信息量） |
| F-6 | P3 | DEC-id 裸子串匹配 | `DEC-1` 被 `DEC-10` 满足 | **已修**：边界正则 + 单测 |
| F-7 | P3 | `_strip_annotation` | 含 `(` 的合法路径被截断 | **已修**：先试原串 + 单测 |
| F-8 | P3 | `security-r3.md`/`acceptance-te.md` | 无覆盖标签槽位 | **已修** |
| F-9 | P3 | 评审输入 | patch 缺 arb | 原因：生成 patch 前把新 arb 复制进了基线目录跑 gen-l10n → diff 为空；记 LESSONS L-11（基线目录只读） |
| F-10 | P3 | `mutate.py` | `read_bytes` 在 try 外；重复 id 静默覆盖 | **已修** |
| F-11 | P3 | `gates.sh` | CANARY 允许列表过宽；`PASS()` 可读性 | **已修** |
| F-12 | P3 | 告警语义 | 页面可灌大 `wsMessages` 压占比（可接受，原始计数并排可见）；OB207 阈值 1 保留；注释"样本"应为"未命中数地板" | 注释已修；分母抗抑制登记候选 W-014（P3） |
| F-13 | P3 | 白名单增长无护栏 | 新增计数键时策略静默不告警 | **已修**：`consumedKeys`/`ignoredKeys` + 测试"并集 == 全部已知键且不交" + 变异 |

## 评审员核实记录（摘要）

- 阈值逐条与纲领 §3 W-005 ① 一致；`codesLine` 顺序 = 规则序；`_alertLabel` 为无 default 的 switch 表达式，新增枚举值编译期报错。
- 敌对输入：负数→0、缺键→0、非白名单键忽略、`1<<62` 钳到 `1<<40`；去掉钳位时 `(1<<62)*2` 回绕为负使告警**消失**——变异已抓住。
- 诊断红线：页面新增输出只有 `app·OBxxx`/`短id·OBxxx` 键、l10n 常量、int；诊断包只有 `OB2xx` 逗号串或 `none`。
- 亮点：钳位使乘法对任何调用方输入不溢出；页面与诊断包共用同一策略。
