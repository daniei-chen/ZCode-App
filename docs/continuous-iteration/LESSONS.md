# LESSONS — 自迭代台账（agent RSI 回路）

> 规则见 `EXECUTION_PROGRAM_8H.md` §4：每轮至少一条教训，且必须落实到工件（有 diff）；"下次注意"不算落实。
> 曲线口径：**工具调用数** = 主代理该轮的工具调用次数（估算标 ≈）；**门禁墙钟** = 从导出到最后一道本地门的秒数；**审计返修率** = 首轮发现数 / 其中需返修数 / 复核新发现数；**人工步骤** = 脚本未覆盖、靠手敲/重试完成的步骤数。

## 一、教训 → 落实

| # | 来源轮 | 教训 | 落实工件（diff） | 预期改善指标 | 生效验证轮 |
|---|---|---|---|---|---|
| L-01 | iter1 | 审计报告没落盘（子代理无 Write，主代理忘写） | `tools/iteration/prompts/*.md` 头部声明"报告由主代理写入 docs/audits/"；验证器 `--repo-root` 校验 `audits[].report` 存在 | 人工步骤 −1 | iter3 |
| L-02 | iter2 | skill 目录被外部删除，我对验证器的改进（--repo-root 等）随之**永久丢失**——流程工件只活在用户配置目录 | 工具链入仓 `tools/iteration/`（验证器 + 自测 18 条 + 合同文档），版本化 | 丢失风险 → 0 | RSI-0 |
| L-03 | iter2 | 变异验证手写 heredoc，转义两次失败才跑通 | `tools/iteration/mutate.py` 声明式 JSON 语料（`mutations/iter1.json`、`iter2.json`） | 人工步骤 −2 | RSI-0：3/3 一次通过 |
| L-04 | iter2 | OSV 需 SBOM 路径 + exceptions 参数，翻了 3 次日志才拼对 | `gates.sh --osv` 固化参数与 SBOM 路径（`ZR_SBOM` 可覆盖） | 人工步骤 −3 | RSI-0 |
| L-05 | iter2 | 秘密扫描正则比 iter1 宽，2 条测试 CANARY 误报要人工解释 | `gates.sh` 固化正则 + CANARY 允许列表，日志同时给 raw/effective 两个数 | 人工步骤 −1 | RSI-0 |
| L-06 | iter2 | T3 因审计覆盖未较上轮升级而 OPEN，直到 sync 才发现 | 纲领 §1/§5 覆盖阶梯；`review-r2.md` 强制填 `{{COVERAGE_TAGS}}` | T3 在 iter3 转 DONE | iter3 |
| L-07 | iter2 复核 N-1 | 代码注释引用了尚未登记的缺陷号 | 验证器新增检查：`lib/test/tools/scripts` 中 `D-YYYYMMDD-NN` 必须在 DEFECTS.md | 复核新发现 −1 类 | iter3 |
| L-08 | iter1 追溯 | W-001/W-002 标 DONE 但没挂 review_id，状态与审计脱节 | 验证器新增检查：DONE 候选必须有存在的 review_id；已回填 A-102 | 状态一致性 | RSI-0（首跑即抓到） |
| L-09 | RSI-0 | 内嵌 python heredoc 里写测试源码，`\\n` 被吃掉一层变成真换行，文件语法错 | 规则：测试/脚本一律用 Write 工具整文件写，不经 heredoc；`test_repo_links.py` 独立成文件 | 人工步骤 −1 | RSI-0 |
| L-10 | RSI-0 | Windows 下 `subprocess.run(["flutter", ...])` 找不到 .bat | `mutate.py` 用 `shutil.which("flutter")` 解析 | 跨平台一次通过 | RSI-0 |
| L-11 | iter3 F-9 | 生成评审 patch 前把新 arb 复制进基线导出目录跑 gen-l10n，diff 被污染（评审员拿到的 patch 缺 arb） | README 红线：基线导出目录只读，生成步骤另开导出 | 评审输入完整性 | iter4 |
| L-12 | iter3 | heredoc 内嵌 python 打补丁**第三次**因转义静默失败（gates.sh CANARY 正则 + 提示词）；L-09 只写了"测试源码"，没覆盖脚本/正则 | README 红线升级为"含反斜杠/正则/转义的文件一律用编辑器工具" | 人工步骤 −1/轮 | iter4 |
| L-13 | iter3 F-1 | `validate --repo-root .` 在测试文件落地**之前**跑了一次就当绿，实际加文件后必红（时序性假绿） | `gates.sh` 新增 `state` 门：每轮门禁末尾自动跑 `--repo-root` 校验 | 状态一致性零人工 | iter4 |
| L-14 | iter3 F-2/F-5 | `.gitignore` 整目录忽略 `tools/`、全局忽略 `*.log`：工具链与证据"本机存在、仓库不存在"，验证器只查文件系统看不出来 | `.gitignore` 反向规则 + `gates.sh` state 门加 `git check-ignore` canary（证据日志/工具链/状态 JSON 三类） | 入仓真实性 | iter4 |
| L-15 | iter3 F-3 | 变异语料按"规则"补齐后立刻抓到 OB206 边界值 1 未测（`<= 1` 存活）——**H-3 首份证据**：语料要按规则/分支枚举，不是按测试文件数 | 纲领 §3 验收 ⑥ 口径从"每条规则"落实为 `mutations/*.json` 逐规则一条；D-20260918-04 | 测试真实强度 | iter3（已生效） |
| L-16 | iter3 记账 | 检查点指纹用 `git diff HEAD`，**未跟踪的新文件完全不在指纹里**（iter1 的 subframe_stats.dart、iter3 的 observer_alerts.dart 与整个 tools/ 都不可见，cp-1/cp-2 的指纹实际只盖住了改动的旧文件） | `tools/iteration/fingerprint.sh`：tracked diff + 每个未跟踪非忽略代码文件的路径与内容哈希；cp-3 起采用，E-27 记录配方变更 | 检查点可复现性 | iter4（换配方后指纹随新文件变化） |
| L-17 | iter3 复核 N-1 | 返修说明里写"已登记候选/已记教训"，实际三处都没落地——复核抓到；自动校验不扫 `docs/audits/` 与 LESSONS | 规则：返修说明只写已发生的事，用"将登记"区分；记账步骤顺序改为"先登记、后写说明" | 复核新发现 −1 类 | iter4 |
| L-18 | iter4 F-1 | "每组至少一条变异"≠纲领的"每个新测试一条"：11 条只钉住 7 条，且 feed 用例的断言弱到回退照绿——覆盖靠口头承诺必然打折 | `mutate.py --coverage`（列出未被变异/豁免引用的用例名）+ `mutations/coverage-files.txt` + gates.sh **`mutcov` 必需门**；`exempt`+`covers` 让"无法变异"也必须显式登记；iter3 遗留 5 条一并补齐 | 变异覆盖零人工 | iter4（首跑即抓到 L-19） |
| L-19 | iter4 N-1 | 用 sed 改语料里的 `expect_fail`，因 `json.dump(indent=2)` 把数组写成多行而未命中，后台全语料跑 26/27 | 规则：语料文件只经 json 读改写；`mutcov` 门把这类漂移变成门禁失败 | 人工步骤 −1 | iter4（已生效） |
| L-20 | iter4 N-3 | 规模测试 N=1e5 让"去掉淘汰"变异跑成二次方（291 s → 569 s），拖慢整套语料 | 规则：N 取"远超上界即可"（2e4），把变异成本写进用例注释；`mutate.py --timeout-s`（默认 900）防挂死 | 语料墙钟 −8 min | iter4（已生效） |
| L-21 | iter5 复审 N-1 | 修一类问题必须**枚举同类全部实例**：深度守卫只接了 zrEvents，同预算的 zrWs 通道裸 `jsonDecode` 原样可达（复审阻断项）；令牌守卫同理漏了 back 手势路径（N-2） | 修复时先 grep 同类入口清单再动手；`security-r3.md` 模板"必做检查"加通道完备性条款；每个入口一个回归 | 复审阻断 −1 类 | iter6（模板条款验证） |
| L-23 | iter9 | 变异下**编译失败**既不是通过也不是被抓住——此前被当成"测试通过"（mutation survived）或整文件 load 失败全是噪声，浪费一轮定位 | `mutate.py` 检测 "Failed to load"/"Compilation failed" → 显式 ERROR；规则：变异/恢复严禁用序数 replace（恢复错行会把工作区弄脏，本次实锤） | 噪声轮次 −1 类 | iter9（已生效） |
| L-24 | iter10 | ① Edit 工具报 "file modified" 后**必须重试**——我丢弃了一次失败，pin 测试从未落盘，门禁全绿是"测试不存在"的假象（变异首跑 0/2 才暴露）；② python replace 不带 assert 会静默 no-op（device_store 注释改写未落盘，复核 N-3 实锤） | 规则：a) 任何工具调用失败都重试或显式记录；b) 文本替换一律 assert 计数；c) mutcov 之外补"断言强度"抽查（pin 测试的变异必须真的被抓住） | 假绿 −1 类 | iter10（已生效） |
| L-22 | iter5 | hookScript 整体处于 Dart 插值字符串内：JS 正则的 `$`、甚至注释里的 `$ ` 都是插值错误（编译器当场抓的，门禁有效） | 注入脚本改动必须过 analyze（gates.sh 已强制）；教训已写入脚本内注释 | 人工步骤 0（门禁兜住） | iter5（已生效） |

## 二、四条曲线

| 轮 | 工具调用数 | 门禁墙钟 | 审计：首轮发现 / 返修 / 复核新发现 | 人工步骤 | 备注 |
|---|---|---|---|---|---|
| iter1 | ≈70 | ≈12 min（手工 6 道门 + 2 次返修重跑） | 5 / 5 / 3 | ≈9 | 报告落盘遗漏 1 次 |
| iter2 | ≈45 | ≈10 min（手工，含 OSV 参数摸索与两次 heredoc 失败） | 7 / 4 / 1 | ≈7 | 首次做对抗变异 ×2 |
| RSI-0 | ≈22 | **64 s**（`gates.sh rsi0 --osv`，8 道门一条命令） | — | 2（heredoc、.bat） | 变异 3/3 一次通过 |
| iter3 | ≈40 | **66 s**（9 道门含 state） | 13 / 12 / 6（记账类） | 3（const-for 编译错、heredoc、基线污染） | 审计抓到 2×P1 全在工具链；变异抓到 1 测试缺口；覆盖升级 ADVERSARIAL；**T3 DONE** |
| iter4 | ≈35 | **72 s**（11 道门含 mutcov） | 8 / 8 / 4 | 2（sed 改 json 失败、global 声明顺序） | 审计 1×P1（变异覆盖）；工具新增 exempt/coverage/timeout/mutcov 门；覆盖升级 SCALE_DATA；语料 27+2 |
| iter5 | ≈45 | **74 s**（11 道门严格 state） | 9 / 13（含 4 残留收口）/ 7（含 1 阻断：跨通道不完备 L-21） | 3（漏 import、$ 插值 ×2） | 安全 R3：2×P2 进程级击杀面全部闭环，评级降至**中低**；debug APK 门 PASS；语料 31+4；覆盖 ADVERSARIAL+BOUNDARY_CONTRACT |
| iter6 | ≈40 | **76 s**（11 道门严格 state） | 6 / 6 / 1（收敛重构丢守卫 F-8） | 1（l10n 键） | 用户反馈直修（静默刷新）；审计 1×P1（全体解盖）当轮闭环；覆盖 DIFF+BOUNDARY |
| iter7 | ≈30 | **78 s** | 双审计：13 / 13 / 4 | 4（dart:io、l10n 作用域、CJK 载荷 ×2） | 服务面 B+（3×P2 全闭）+ 独立验收 11 项抽样（8 确认/3 补齐）；TE 当场落守卫测试；候选 +W-018..021 |
| iter8 | ≈45 | **82 s** | UI 审计 7 / 7 / 0（机器验证 A-117） | 4（l10n 作用域、CRLF ×2、helper 残留） | 2×P2 大字体可达性修复；D-20260919-01 测试边界抖动；683/683 |
| iter9 | ≈50 | **84 s** | — | 6（Write 截断、import 路径 ×2、Stack 括号、sync 闭包 await、恢复用序数替换弄脏工作区） | 用户需求直修（连通性绿/橙点，W-023）；**mutate.py 补编译失败检测（L-23）**；变异 7/7；692/692 |
| iter10 | ≈35 | **85 s** | 合并复核 iter8+9：8 / 8（含 1 错 catch）/ 3（N-1 错 catch、N-2 台账、N-3 注释） | 2（Edit 失败未重试、replace 无 assert） | 独立复核恢复；F-3 supersedeable 通道设计干净；694/694 |
| 收尾轮（iter11） | ≈40 | ≈90 s | 复核 10 / 10 / 0 | 2 | 700/700；语料 76+6 |
| iter12 | ≈60 | 门禁 ≈95 s×2（一轮返修重跑）+ 变异 ≈13 min×3 | 深探 21（证实14/证伪1/裁定1/候选化5）/ 修复 14 / 复核 12（2×P1 语料+阈值带、1×P2 竞态、1×P2 休眠钟、6×P3） | 5（heredoc unicode ×2、python 双写、测试竞态 drain、CRLF 误判） | 725/725；语料 100/100+7；W-018/W-021 闭环；新候选 W-025..030 |
| iter13 | ≈25（workflow 编排，主代理仅修 run 环境） | 门禁 ≈70 s；变异全语料补跑 | 工作流内零上下文复核一轮通过，5 注记当轮闭环（F-1 变异补跑/F-2 自测接线/F-3 死代码/F-4 计数/F-5 元数据） | 1（world.run PATH） | 702/702；W-015/026/030 关闭；CI ci/ci-heavy 实跑 success |

## 二.5、iter12 新教训（L-25–L-27）

- **L-25（改代码先查语料）**：修复批动到旧变异锚时，先对全部语料 find 串做唯一性预检——iter12 改 `_boundedTitle`/`probeUri`/合并驱逐后，iter5/iter9 三条旧锚 0 命中（ERROR）或被更强守卫掩盖（survived）。正确顺序：改代码 → 语料预检 → 全语料重跑；被新守卫覆盖的旧变异转 declared exempt 并写明理由，不得静默删除。
- **L-26（heredoc 转义第 4 课）**：含 Dart/正则转义的补丁（`\u{...}`、`\+`）在 bash heredoc + python 非原始字符串里必炸。一律 r-string 拼接，必要时 `chr(92)` 组装单反斜杠；写完用 `cat -A`/grep 验证落盘字节，不要信"替换成功"的输出。
- **L-27（测试编排竞态）**：widget/container 测试里 `read(provider)` 触发 build→异步 `_load`→report 的链路，会把同步断言目标（擦除后应为 null 的状态）在毫秒级顶回来。断言前 drain 在途异步（`Future.delayed` + 注释论证生产无此窗口），断言本身保持严格。

- **L-28（world.run 无 profile PATH）**：dynamic-workflow 的 world.run 直接 spawn、不经 shell profile——Windows 上 `bash` 不在 PATH（spawn ENOENT），flutter/python 同理可能缺失。解法：命令用绝对路径（PortableGit usr/bin/bash.exe）+ `-lc` 登录 shell 继承 PATH；先在会话内确认绝对路径再写进脚本。

## 三、待观察的假设

- H-1：`gates.sh` 把门禁墙钟从 ~10 min 压到 ~1 min 后，每轮总工具调用数应降到 ≤30（iter3 40 / iter4 35：趋势对但未达标——审计返修占大头，见 H-2）。
- H-2：`review-r2.md` 的"必查通用项"能把复核新发现压到 0（iter3 6 / iter4 4：**未成立**，新发现主要是"我声称已做但没落地"与"工具接线缺失"两类 → L-17 规则 + mutcov 门；iter5 再验，连续两轮不成立则修模板：加"返修说明须附机器证据"条款）。
- H-3：变异语料库累计运行会抓到"测试被意外削弱"的回归——**已成立**（iter3 抓 OB206 边界、iter4 抓"负数按 0"守不住 + sed 漂移）。
