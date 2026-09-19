# EXECUTION_PROGRAM_8H — ZCode App 八小时自迭代施工纲领

> 生成：2026-09-18 · 基线：`release/v1.0.0 @ 16a7d8e`（未提交改动 = iter1 + iter2，见 `ITERATION_STATE.json` cp-2-iter2）
> 机器权威仍是 `docs/continuous-iteration/ITERATION_STATE.json`；本文是施工图，不是状态。
> 配套：`EXECUTION_PROMPT.md`（单轮协议）、`LESSONS.md`（自迭代台账）、`tools/iteration/`（流程工具链）。

## 0. 这份纲领要回答的三个问题

1. **项目可行吗？** 可行，但可行性分两半。本地可做的工程面（代码正确性、测试、审计、可观测、流程）已接近饱和：cp-2-iter2 总分 80/100，core 23/24、tests 14/14、docs 9/9。剩余 20 分里 **约 16 分被外部/用户决策锁死**：operations 2/12（CI、真机矩阵、48h soak 需 GitHub 账号与设备）、security 18/24（签名密钥处置 ADR-003 = P0、WebView 隔离 ADR-004、无凭据擦除出口 ADR-005）。**没有任何本地工作能把总分推过 ~82**；目标 85 的最后一段路只能由用户拍板解锁。本纲领的价值不在分数，而在：把本地能做的做尽、把风险面用对抗审计打透、把流程做成自持的——用户一旦拍板，剩下的路是小时级而不是天级。
2. **八小时做什么？** 6 个迭代轮（iter3–iter8）+ 2 个流程自迭代块（RSI-0 自举、RSI-R 复盘）。每轮 = 有界批次 → 导出目录门禁 → 零上下文审计（覆盖标签逐轮升级）→ 返修 → 记账 → 检查点。每轮**必须**向 `LESSONS.md` 写至少一条教训并落实到工具链或提示词（有 diff 才算）。
3. **"自我训练"是什么意思？** 我不能改自己的权重，但能改自己运行所依赖的一切外部工件：验证器、门禁脚本、变异验证脚本、审计提示词、经验台账、恢复提示词。把每轮踩的坑变成脚本里的断言或提示词里的一句话，下一轮就不会再踩——这是 agent 版的 RSI。度量：`LESSONS.md` 的"每轮工具调用数 / 门禁墙钟 / 审计返修率 / 人工步骤数"四条曲线要单调改善，否则说明改进无效，回滚。

## 1. 硬约束（沿用，逐条不可违反）

- **DEC-06**：不提交、不推送、不打 tag。结束时 `git status --porcelain` 报告未提交清单。
- **DEC-02/DEC-14 陷阱**：`flutter test`/`analyze`/`build` 一律在导出目录跑（`git archive HEAD` + 覆盖工作树改动），**永不**在真实工作区跑；工具链 `tools/iteration/gates.sh` 强制这一点。
- **密钥红线（D-16 P0）**：不读取、不输出、不复制 `android/key.properties`/keystore；**不做 release 出包**。编译可行性只用 `--debug`。
- **诊断红线**：诊断页/诊断包/日志只出现数字、枚举、短 id；任何 URL/host/正文/凭证不得进入新增字段。
- **质量棘轮**：不删测试、不降断言、不吞异常换绿；P1 必有回归测试；每个新测试必须通过"回退即失败"变异验证（`tools/iteration/mutate.py`）。
- **审计独立性**：每轮 R2 审计由零上下文子代理执行；返修后复核；报告**必须落盘** `docs/audits/`（iter1 教训 N-4）。
- **T3 覆盖升级**：相邻两个清洁轮次审计覆盖必须有新标签；本纲领的升级阶梯：iter3 `ADVERSARIAL` → iter4 `SCALE_DATA` → iter5 安全 R3（`ADVERSARIAL`+`BOUNDARY_CONTRACT`）→ iter6 独立验收 → iter7 `RESILIENCE` → iter8 `CLEAN_START_RELEASE`。
- **诚实计分**：BLOCKED 计 0 且留在分母；网络故障的门禁记 BLOCKED 不记 PASS；分数不涨就写不涨。

## 2. 时间盒与批次（8h）

| 块 | 时段 | 编号 | 批次内容 | 产物 | 通过门 | 覆盖标签 |
|---|---|---|---|---|---|---|
| RSI-0 | 0:00–0:45 | **W-007**（P2，流程） | 流程工具链入仓 `tools/iteration/`：验证器（重做丢失的 `--repo-root` 引用/哈希校验 + 自测）、`gates.sh` 导出目录门禁一键、`mutate.py` 变异验证、审计提示词模板 ×3、`LESSONS.md` | 工具链 + 自测通过 + EXECUTION_PROMPT 引用 | 验证器自测全绿；`gates.sh` 在 cp-2 上复现 iter2 结果（619/619） | — |
| H1 | 0:45–2:00 | **W-005**（P2） | 观察面变化自动告警：`ObserverAlertPolicy` 纯函数（14 计数键 + 子 frame 计数 + 桥丢弃）→ 告警枚举；诊断页"观察面告警"分节；诊断包新增 `alerts`（仅枚举码）；l10n；PRIVACY 同步；测试含敌对计数（负数/超限/缺键/溢出） | 代码 + 测试 + 文档 | G-001..G-007 + mutate 通过 + R2 审计 | `ADVERSARIAL` |
| H2 | 2:00–3:00 | **W-004**（P3）+ **W-008**（P3） | W-004：BENCHMARKS-RESULTS 模拟数据标注复核；W-008：规模测试——dedupe 闸门 10⁵ 事件时间/内存上界、`EventParser.dedupe` 大数组、feed 10⁴ 事件、`acceptStats` 8 KiB 边界、`LogRedactor` 长输入；每条有明确上界断言 | 测试 + 文档 | 同上 | `SCALE_DATA` |
| H3 | 3:00–4:00 | **W-009**（P2） | 零上下文 **security-auditor R3** 对输入面（`bridge_schema`/`event_observer` 解析/`link_builder`/`update_service` 出站/`webview_storage`）做对抗审计；产出缺陷 → 登记 → P1/P2 当轮修，P3 入候选 | 审计报告 + 缺陷 + 修复 | 同上 | `ADVERSARIAL`+`BOUNDARY_CONTRACT` |
| H4 | 4:00–5:00 | **W-010**（P2） | 零上下文 **test-engineer 独立验收**：抽样 10 条 PASS 验收项，逐条用"回退即失败"复核声明；不成立的**诚实降级**（PASS→PARTIAL/FAIL）并开缺陷 | 验收报告 + 矩阵修订 | 同上 | 独立验收 |
| H5 | 5:00–6:00 | **W-011**（P2）+ 修复批 | 编译可行性门 **G-010**：导出目录 `flutter build apk --debug` + 插件存活脚本（debug 形态，信息性）；同时修 H3/H4 产出的 P1/P2 | APK 构建日志 + 修复 | G-010 + 同上 | `RESILIENCE` |
| H6 | 6:00–7:00 | **W-012**（P3） | 冷启动门 `tools/iteration/clean_start.sh`（fresh archive → pub get → analyze → test → gen-l10n 漂移 → debug build）；文档一致性扫描（SUPPORT/PRIVACY/ROADMAP 对新增诊断分节） | 脚本 + 文档 | 同上 | `CLEAN_START_RELEASE` |
| RSI-R | 7:00–7:40 | **W-013**（P3，流程） | 复盘：从 `LESSONS.md` 四条曲线判定哪些流程改进有效；工具链 v2；恢复提示词更新（新会话 5 分钟内可续跑） | LESSONS 结论 + 工具链 diff | 验证器/自测全绿 | — |
| 收尾 | 7:40–8:00 | — | OSV 再试；全门禁终跑；状态 JSON 终态；渲染；最终报告（状态行 + 未提交清单 + 用户待拍板清单） | 报告 | validate/sync/render exit 0 | — |

> 时段是预算不是承诺：某块提前完成就把余量给下一块的返修；某块超时 25% 就把未完成部分拆成候选留给下一轮，不压缩审计与记账。

## 3. 批次级验收（每个 W 都要过）

| ID | 验收要点（可判定） | 证据落点 |
|---|---|---|
| W-007 | ① `tools/iteration/iteration_state.py validate --repo-root .` 对 cp-2 状态 exit 0，且在人为删掉一个证据文件后 exit≠0；② `test_iteration_state.py` 全绿含 ≥6 条新用例（缺失证据/缺失报告/哈希不一致/矩阵改动未记 history/审计报告未落盘/候选 DONE 无 review_id）；③ `gates.sh i2b` 在当前树复现 619/619 与 iter2 各门结果；④ `mutate.py` 用 iter2 的两条变异（旧键 / 标记去尾）跑通并断言"仅目标用例失败"；⑤ 三份审计提示词模板含覆盖标签槽位与"报告必须落盘"条款 | `docs/continuous-iteration/evidence/rsi0-*.log` |
| W-005 | ① 纯函数对 14 键全零 → 无告警；`sseIgnored≥1`/`sseMessages≥1` → `SSE_APPEARED`；`wsIgnored≥20 且占比>50%` → `WS_MISS_HIGH`；`fetchSkipped≥20 且占比>50%` → `FETCH_MISS_HIGH`；`invalidFragments+expiredFragments≥5` → `FRAGMENT_ANOMALY`；`queueDropped+seenDropped≥1` → `BUDGET_DROP`；桥 `droppedMessages≥1` → `BRIDGE_DROP`；子 frame `cancelled≥1` → `SUBFRAME_BLOCKED`；② 敌对输入：负数/超 `maxStatValue`/缺键/非白名单键 → 不崩、不告警或按缺席处理，绝不抛；③ 诊断页新分节每设备只显示告警枚举与触发计数（数字）；④ 诊断包 `alerts` 字段仅枚举码；⑤ PRIVACY.md §五 增补"观察面告警码（枚举，由计数派生）"；⑥ 每条规则都有"回退即失败"变异 | 测试文件 `observer_alert_test.dart`；`i3-*.log`；审计报告 |
| W-004 | BENCHMARKS-RESULTS 里所有模拟/合成数据行带醒目标注且与 A-12 审计意见一致；无"看起来像实测"的合成数字 | 文档 diff + 审计意见对照 |
| W-008 | 每条规模测试有显式上界（条目数/长度/幂等等结构断言为主；**允许每条用例附一道 20 s 级的灾难性退化绊线**——它只抓二次方爆炸这类量级退化，比预期慢三个数量级才触发，不作性能基准）；总测试墙钟增量 < 10 s；每条用例有"回退即失败"变异，无法构造有意义变异的用例须在 `mutations/*.json` 以 `exempt` + 理由显式登记 | `i4-test.log` 计时；`i4-mutations.log` |
| W-009 | 安全审计报告落盘；每条发现有复现步骤；P1/P2 有修复 + 回归测试 + 变异验证 | `docs/audits/2026-09-18-security-r3.md` |
| W-010 | 验收报告落盘；每条抽样有 PASS/FAIL + 证据；矩阵与状态 JSON 同步（分数如降就降） | `docs/audits/2026-09-18-acceptance-te.md` |
| W-011 | 导出目录 debug APK 构建 exit 0；APK 存在且大小合理；插件存活脚本对 debug 形态结果记入证据（信息性） | `i5-build.log` |
| W-012 | `clean_start.sh` 在全新导出目录一键 exit 0；`gen-l10n` 输出与仓库文件无 diff | `i6-cleanstart.log` |
| W-013 | LESSONS 四条曲线表填满 iter3–iter8；至少 3 项流程改进有"生效证据"（后续轮次指标改善）或被明确回滚 | `LESSONS.md` |

## 4. 自迭代回路（RSI）规范

每轮 CHECKPOINT 之后、DECIDE 之前，强制执行：

1. **采集**：本轮工具调用数、门禁墙钟（`gates.sh` 自报）、审计首轮发现数 / 返修项数 / 复核新发现数、人工干预步骤数（脚本没覆盖、我手敲的步骤）。
2. **归因**：每个人工步骤或返工问"哪个工件缺了什么断言/哪句提示词没说清"。
3. **落实**：改工具链或提示词，**带 diff 与自测**；只写"下次注意"不算落实。
4. **登记**：`LESSONS.md` 一行：轮次 / 教训 / 改动工件 / 预期指标 / 生效验证轮次。
5. **回滚规则**：某项改进连续两轮未改善其预期指标 → 回滚并记录。

已知待落实教训（来自 iter1/iter2，RSI-0 处理）：

| 来源 | 教训 | 落实 |
|---|---|---|
| iter1 N-4 | 审计报告忘记落盘 | 提示词模板含"主代理必须把报告写入 docs/audits/"；验证器 `--repo-root` 校验 `audits[].report` 存在 |
| iter2 | skill 目录被删，流程改进随之丢失 | 工具链入仓 `tools/iteration/`，版本化 |
| iter2 | 变异验证手写 heredoc 转义两次失败 | `mutate.py` 声明式变异 |
| iter2 | OSV 需要 SBOM 路径与 exceptions 参数，找了 3 次 | `gates.sh --osv` 固化参数与 SBOM 路径 |
| iter2 | 秘密扫描正则比 iter1 宽，误报 2 条 CANARY | `gates.sh` 固化正则 + 允许列表（测试 CANARY 文件） |
| iter2 | T3 因覆盖未升级而 OPEN | 纲领 §1 覆盖阶梯；提示词模板强制填标签 |
| iter2 复核 N-1 | 代码注释引用了尚未登记的缺陷号 | 验证器新增检查：`lib/`/`test/` 中 `D-YYYYMMDD-NN` 引用必须在 DEFECTS.md 存在 |

## 5. 审计覆盖阶梯与提示词

| 轮 | 代理 | 覆盖标签 | 提示词模板 | 重点 |
|---|---|---|---|---|
| iter3 | code-reviewer | DIFF_CORRECTNESS + BOUNDARY_CONTRACT + **ADVERSARIAL** | `tools/iteration/prompts/review-r2.md` | 敌对计数输入、误报率、诊断红线 |
| iter4 | code-reviewer | + **SCALE_DATA** | 同上 | 上界断言是否真实约束、测试是否可能抖动 |
| iter5 | security-auditor | ADVERSARIAL + BOUNDARY_CONTRACT（R3） | `prompts/security-r3.md` | 输入面：桥消息/遥测/分片/出站 URL/存储 |
| iter6 | test-engineer | 独立验收 | `prompts/acceptance-te.md` | 抽样 PASS 项复核，回退即失败 |
| iter7 | code-reviewer | + **RESILIENCE** | `review-r2.md` | 构建/插件存活/失败路径 |
| iter8 | code-reviewer | + **CLEAN_START_RELEASE** | `review-r2.md` | 冷启动脚本、文档一致性 |

## 6. 停止与升级规则

- **继续**：批次完成且 validate/sync exit 0，派生状态 CONTINUE，且候选池仍有 LOCAL 项。
- **转 BLOCKED**：候选池无 LOCAL 项（预计在 iter8 后）→ 输出用户待拍板清单（ADR-003/004/005、tag 策略、GitHub 账号、真机窗口、公网 DNS）。
- **中止当前批次**：门禁连续两次同因失败且不是我引入的（环境问题）→ 记 BLOCKED，换下一批次。
- **绝不**：为凑分改矩阵权重（DEC-16 冻结）、把 BLOCKED 写成 PASS、跳过审计、跳过记账。

## 7. 报告格式（每轮末尾 + 最终）

```text
ITERATION <n> | STATUS: CONTINUE|BLOCKED | SCORE: <prev>→<cur> | OPEN P0/P1: <p0>/<p1> | NEXT: <one action>
```

随后：本轮变更 / 门禁与证据 / 审计与返修 / 台账变化 / RSI 落实（工件 diff）/ 阻塞与下一动作。最终报告追加：未提交清单、用户待拍板清单（每项：推荐选项 + 风险 + 解锁后我能在多长时间内完成什么）。
