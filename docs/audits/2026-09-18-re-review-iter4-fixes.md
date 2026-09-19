# 返修复核：ITERATION 4 批次（W-004 + W-008）

- **日期**：2026-09-18
- **评审方式**：首轮同一 code-reviewer 子代理（iter4 新代理）续会话复核（只读）
- **覆盖标签**：DIFF_CORRECTNESS + SCALE_DATA
- **前置报告**：`docs/audits/2026-09-18-code-review-iter4.md`（首轮：1×P1 + 1×P2 + 6×P3，需返修后合并）
- **返修后门禁**：`gates.sh i4 --osv --strict-state` **11 道门全 PASS**（新增 `mutcov` 门；state 严格）；test 646/646，套件墙钟 48 s；变异全语料 **27/27 caught + 2 exempt (declared)**

## 逐项复核

| 项 | 结论 | 要点 |
|---|---|---|
| F-1 变异覆盖缺口 | **PASS** | +4 条变异 find 唯一、`only` 精确（日志逐条 1 个目标用例失败）；`exempt` 机制"列出不计数"语义正确；豁免依据（`official_remote_page.dart:1611` WebView handler）属实；11/11 = 10 变异 + 1 豁免 |
| F-2 绊线与验收自洽 | **PASS** | 纲领 W-008 行、实现、豁免机制三方一致 |
| F-3 时钟确定性 | **PASS** | 单调假时钟每次 +1 ms，最大偏移 < 窗口，淘汰全序确定 |
| F-4 末值生效 | **PASS** | 首 1 末 5 逐键断言可区分 putIfAbsent；两条 feed 变异被抓 |
| F-5 幂等整列表 | **PASS** | 唯一键保留同实例，恒等比较成立 |
| F-6 ≥1 MiB | **PASS** | 1,107,780 > 1,048,576；`output.length < input.length` 成立 |
| F-7 诊断夹具 | **PASS** | 1000 互异短 id；全 1 计数下每行恰 `OB201,OB205`，推导确定 |
| F-8 横幅措辞 | **PASS** | 测量数据/溯源信息已区分；日期有证据日志时间戳佐证 |

## 新发现与处置

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| N-1 | P2 | 豁免条目缺 `covers`，新增的 `--coverage` 对自己登记的用例报未覆盖；且 `--coverage` 未接入 gates.sh，机制休眠 | **已修**：`covers` 补齐；新增 `mutations/coverage-files.txt` + gates.sh **`mutcov` 门**（必需，静态检查）；首跑即抓到一条 sed 未改到的旧用例名（json.dump 多行数组），已用 json 正确修正 |
| N-2 | P3 | 豁免理由引用旧用例名与不存在的验收编号 ⑥ | **已修** |
| N-3 | P3 | no-eviction 变异 569 s 且无超时 | **已修**：用例 N 降为 2e4（有界性质不变，变异下二次方成本从 9 分钟降到十几秒）；`mutate.py --timeout-s`（默认 900，超时计不通过） |
| N-4 | P3 | PROJECT_AUDIT A-12 摘要未随横幅细化同步 | **已修** |

## 最终结论

**可以合并。** 复核原判"可以合并（建议顺手带上 N-1）"，N-1..N-4 已全部落地并经 `gates.sh --strict-state`（含 mutcov）与全语料 27/27 机器校验。
