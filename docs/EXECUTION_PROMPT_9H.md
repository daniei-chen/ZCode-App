# EXECUTION_PROMPT_9H — ZCode App 生产改进施工提示词（9 小时）

> 可整体复制给执行 AI。生成日期 2026-09-16；基线 `release/v1.0.0 @ 16a7d8e`（1.0.0+26）。
> 配套文档（先读）：`docs/PROJECT_AUDIT.md`、`docs/PROJECT_MASTER_PLAN.md`、`docs/ACCEPTANCE_MATRIX.md`；滚动台账 `docs/PLAN-v1.1.0.md`、`docs/releases/v1.0.0.md`。

## 0. 身份与目标

你是 ZCode App 的执行工程师。仓库绝对路径：`D:\AI\zcode\ZCode App`（Git Bash 下 `/d/AI/zcode/ZCode App`）。Flutter 在 `D:\phone\flutter\bin`，JDK 17 在 `D:\phone\Java\jdk-17.0.20.1+1`，adb 在 `D:\phone\Android\android-sdk\platform-tools`。

本轮目标（生产改进，不是新功能）：

1. 落地 **R-19 待处理交互按计数记账**（含"缺 summary = 未知"不变量），全绿并通过独立复审。
2. 产出并落盘 **ADR-001～005**（R-19 已定；R-14、密钥处置、每设备 WebView 隔离、无凭据机型出口为候选方案 + 推荐 + 待用户拍板）。
3. **公网 OSV 依赖扫描**实跑一次并登记结果。
4. 三道零上下文独立审计（架构正确性 / 安全 / 独立验收）→ 缺陷闭环。
5. 台账与四份治理文档同步；`docs/EXECUTION_STATE.md`、`DEFECTS.md`、`EVIDENCE.md`、`DECISIONS.md` 持续更新。

## 1. 不可违反的约束

- **不修改用户未提交改动的意图**：工作区 5 个文件是 R-19 半成品，在其基础上继续，不回退、不用 `git checkout --`/`git stash drop`/`git clean` 一类命令。
- **不提交、不推送、不打 tag**，除非用户明确要求；结束时用 `git diff --stat` 报告未提交清单。
- **生成文件陷阱**：`android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java`（未跟踪）会被 `flutter test`/`flutter analyze` 重写为 debug 形态（12 插件），之后本地出包会失败或产出剥插件坏包。在真实工作区跑测试前 `cp` 备份到 `D:\tmp\zr\GeneratedPluginRegistrant.java.bak`，跑完 `cp` 恢复；或在 `D:\tmp\zr\baseline_head_16a7d8e`（已 `pub get`）拷入改动文件迭代。
- **`android/local.properties`** 可能被工具链写成中文路径导致构建失败：出包前检查 `flutter.sdk=D:\\phone\\flutter`。本轮**不出 APK**。
- **安全红线**：不绕过官方鉴权、不伪造请求、不上传数据；出站请求仅 https 白名单且逐跳校验、拒绝 localhost/环回/私网/保留地址；凭据只从环境变量或安全存储读取，源码/示例/测试不写可用凭据字面量；不输出任何秘密值。
- **质量棘轮**：不删测试、不降断言、不吞异常换绿；每个 P1 修复必须有回归测试；文档随行为变化同步（`SUPPORT`/`PRIVACY`/台账）。
- **停止条件**：只有 §7 交付定义有证据，或有效预算确实用尽，才输出最终报告。编译通过、测试变绿、文档写完都不是停止条件。

## 2. 时间盒（9h）

| 时段 | 阶段 | 行动 | 产物 | 通过门 |
| --- | --- | --- | --- | --- |
| 00:00–00:30 | 接管与基线 | 读四份文档与台账；`git status`；在 `D:\tmp\zr\baseline_head_16a7d8e` 确认 574/574（已有日志可直接引用）；登记 EVIDENCE | `EXECUTION_STATE.md` 开工记录 | 基线结论与审计一致 |
| 00:30–02:00 | P1：R-19 收尾 | ① `TaskIndexExtractor._stateOf` 设 `hasPendingSummary: pendingSummary != null`；② `StateDiffer.apply` 跨投递沿用：prev 带 summary 且 next 不带 → 沿用 prev 计数写入基线（加 `SessionState.inheritPendingFrom`）；③ 测试：跨投递扁平行不发假 resolved、沿用后同计数不重复发请求；④ 临时目录迭代 → 真实工作区备份/跑/恢复 | 代码 + 测试 | analyze 0；test 全绿（≥ 574 + 新增） |
| 02:00–03:00 | ADR | `docs/adr/ADR-001`（R-19 计数降级，已决）、`ADR-002`（R-14：证据先行，不盲目 `regexToCancelSubFramesLoading`）、`ADR-003`（密钥处置三选一：保持+监控 / v3 轮换 / 全新密钥+重装）、`ADR-004`（每设备 WebView 隔离）、`ADR-005`（无凭据机型知情确认出口） | 5 份 ADR | 每份含背景/候选/验证/推荐/回退/复审时间 |
| 03:00–05:15 | 核心闭环巩固 | 全量回归；`node scripts/check_injected_js.mjs`；`python scripts/check-doc-drift.py`；补 R-19 行为到 `docs/PRIVACY.md`/`SUPPORT.md` 若有语义变化；`ACCEPTANCE_MATRIX` B4–B6 回填 | 证据条目 | JS 门 49/49；doc-drift 全过 |
| 05:15–06:00 | 安全与可观测 | `python scripts/check-dependency-advisories.py`（公网 OSV，只读；失败按网络阻塞记录不伪装通过）；`git grep` 秘密扫描复核 | EVIDENCE 条目 | 无新增 high/critical 或已登记例外 |
| 06:00–07:15 | 独立审计 | 并行派出三个零上下文只读代理（§4），报告落 `docs/audits/`；发现全部进 `DEFECTS.md` | 3 份报告 | 无未登记发现 |
| 07:15–09:00 | 返修与交付 | 按 P0→P1→P2 修复；相关测试 + 全量回归；新的零上下文代理复审；台账 `docs/releases/v1.0.0.md` 增 R-19 节、`PLAN-v1.1.0.md` R-19 行改状态；四份文档状态回填；最终报告 | 全部文档同步 | P0/P1 清零或明确阻塞 |

时间有余按此顺序继续：P0/P1 → 核心正确性/权限测试 → E2E 准备 → 恢复与运维 → 可访问性/性能 → 视觉 → P2/P3。不要用无验证的新功能填时间。

## 3. 核心纵向闭环（本轮守护的链）

```
扫码/链接导入 → 生物识别门禁 → 进入设备 WebView(generation)
→ 桥消息 decode → SessionState/TaskIndex 抽取 → StateDiffer(计数转移)
→ EventDedupeGate → event_feed(按任务剩余计数记红点) / 系统通知 / 浮窗卡
→ 点击通知跳回对应会话 → 用户解决交互 → resolved(带剩余量)
→ 剩余>0 保留红点与通知；=0 清除；任务消失(removed)清除
→ 重连/快照替换/扁平行投递后：不重复提醒、不假 resolved
```

逐节点证据：`bridge_message_pipeline_test`、`event_parser_test`（差分组 + R-19 组）、`event_feed_test`（R-19 组）、`notifier_test`、`security_invariants_test`。

## 4. 零上下文独立审计提示词（用 Agent 工具新建代理，代理无本对话历史）

### 4.1 架构与核心正确性（subagent_type: code-reviewer）

```text
你是零历史、完全独立的只读审计代理。仓库：D:\AI\zcode\ZCode App。不要修改文件。
审计范围：git 工作区未提交改动（`git diff`）——R-19 待处理交互按计数记账：lib/services/event_observer.dart（ObservedEvent.pendingTotal、SessionState.hasPendingSummary、StateDiffer 合并/沿用规则）、lib/state/event_feed.dart（pendingByTask 计数记账）、lib/services/webview_sync.dart（resolved 撤销通知条件）及对应测试。
不相信任何完成声明。自行核对：① 同任务审批+输入并存解决一条不清红点；② 缺 summary 的扁平行在同投递与跨投递都不产生假 resolved；③ 沿用基线计数后不重复发 permission_request；④ removed 路径、unknown 占位键、无计数的显式页面事件三条旧语义未被破坏；⑤ EventDedupeGate 与 EventParser.dedupe 交互是否会丢掉带计数的事件；⑥ 并发/重连/快照替换后的基线一致性。
按 P0/P1/P2/P3 输出：文件与精确行号、复现步骤、影响、根因、最小修复方向、复验方法。最后给关键不变量 PASS/FAIL/UNKNOWN 表。
```

### 4.2 安全、权限与供应链（subagent_type: security-auditor）

```text
你是零历史、完全独立的只读安全审计代理。仓库：D:\AI\zcode\ZCode App。不得修改文件、不得输出秘密值、不得触达真实生产服务。
检查：① 本轮工作区改动是否引入新的信任面（事件计数是否可被页面内容操纵成拒绝服务或红点风暴）；② 秘密：git 跟踪文件中的 key/jks/env/凭据字面量，`android/key.properties`、`local.properties` 是否被跟踪；③ 出站 URL 策略（lib/services/outbound_url_policy.dart、update_service.dart）是否仍满足 https 白名单/逐跳/拒私网；④ 依赖：运行 `python scripts/check-dependency-advisories.py` 或读取已登记结果；⑤ 日志脱敏与诊断包边界。
按 P0/P1/P2/P3 提供证据、复现、影响、修复与验证。最后只能给 READY、NOT READY 或 BLOCKED BY EXTERNAL，并列出阻断项。
```

### 4.3 独立验收（subagent_type: test-engineer）

```text
你是零历史的独立验收工程师。仓库：D:\AI\zcode\ZCode App。可运行命令，不修改 lib/ 与 test/ 源码。
注意：在真实工作区运行 flutter test 前，先备份 android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java 到 D:\tmp\zr\，跑完恢复；Flutter 在 D:\phone\flutter\bin。
任务：① `flutter analyze` 与 `flutter test` 全量，记录退出码与通过数；② 逐条核对 docs/ACCEPTANCE_MATRIX.md 的 B4、B5、B6，指出对应测试名并确认其断言真的覆盖需求（不接受只测 happy path）；③ 主动寻找不通过的理由：构造一个你认为会失败的场景（例如任务索引扁平行先于镜像、resolved 无 taskId 且带计数、同投递重复副本都带 summary 但计数不同），用临时测试文件验证后删除；④ 输出 pass/fail 结论 + 证据。
```

### 4.4 从零启动与发布门禁（subagent_type: general-purpose，只读）

```text
你是零历史、完全独立的只读发布门禁代理。仓库：D:\AI\zcode\ZCode App。像首次接手的工程师一样，仅依赖 README.md、docs/SUPPORT.md、docs/RELEASE-CHECKLIST.md 在 D:\tmp\zr\baseline_head_16a7d8e（HEAD 干净导出，已 pub get）执行 flutter analyze、flutter test、node scripts/check_injected_js.mjs、python scripts/check-doc-drift.py。不要修改仓库文件。
核对 README 声明与实际（版本单一来源、质量门禁、构建要求）。列出所有命令、退出码与证据路径。最终只能给 RELEASE-CANDIDATE、NOT-READY 或 BLOCKED-BY-EXTERNAL。
```

审计闭环：独立发现 → 主代理复现 → `DEFECTS.md` 建条（ID/严重度/证据/复现/状态） → 修复 + 回归测试 → 全量回归 → **新的**零上下文代理复审 → 关闭或重开。P0/P1 不得因时间不足降级；报告不得只存档不处理。

## 5. 持久化工作记忆（每 30–45 分钟更新）

- `docs/EXECUTION_STATE.md`：开始时间、当前阶段、已完成证据、阻塞、下一时段。
- `docs/DEFECTS.md`：ID、严重度、证据、复现、状态、修复、复审。
- `docs/EVIDENCE.md`：命令、退出码、报告路径、扫描结果。
- `docs/DECISIONS.md`：假设、选项、决定、理由、后果、复审条件。
- `docs/adr/`：重大架构决策；`docs/audits/`：独立审计原始报告。

**续跑协议**：上下文压缩、代理重启或任务续跑后，先读上述文件与 `git diff --stat`，从最近绿色检查点继续；禁止从头重复，禁止依赖聊天记忆。

**阻塞 fallback**：需要用户决策的项（密钥处置、WebView 隔离、无凭据出口、tag 策略）写入 ADR 的"待拍板"并继续其他工作，不停下等待；网络不可用时把 OSV 记为 BLOCKED（不伪装通过）。

## 6. 禁止事项

不执行部署/推送/付费/外部消息；不用危险 Git/文件删除命令破坏用户工作；不用静态数据或硬编码成功冒充闭环；不因编译通过或代码量变大提前结束；不在源码/测试写可用凭据；不把 `flutter test` 跑在真实工作区而不备份生成文件。

## 7. 交付定义与最终回复格式

交付定义：R-19 全绿且三道审计 PASS（或缺陷已闭环/明确阻塞）；ADR-001～005 落盘；OSV 结果登记；台账与四份文档同步；工作记忆文件为最新。

```markdown
# 结论
当前成熟度、目标成熟度和本轮实际达到状态。

## 最重要的发现
- P0/P1 及证据摘要

## 推荐方向
- 架构和产品关键决定（含需用户拍板的 ADR 列表）

## 已生成/更新文件
- 绝对路径与用途

## 外部阻塞与风险
- 凭据、授权、账号、设备或产品决策问题

## 下一步
- 未提交改动清单（git diff --stat）与建议的提交/复审顺序
```
