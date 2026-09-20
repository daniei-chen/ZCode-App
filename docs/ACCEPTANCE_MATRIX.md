# ACCEPTANCE_MATRIX — 验收矩阵

> 2026-09-16 · 每个"完成"必须能映射到测试、命令、页面、截图或数据校验。
> 状态取值（规范化）：`PASS` / `PARTIAL` / `OPEN` / `BLOCKED` / `FAIL` / `DEFERRED` / `NA`。BLOCKED 仍计入分母并阻止 TERMINATED；DEFERRED 需满足延期规则。
> 维度：core（核心）/ security（安全隐私）/ tests（测试证据）/ operations（运维恢复）/ docs（文档交接）。`关键=是` 的条目未 PASS 时禁止 TERMINATED。
> 本文随施工滚动更新；证据明细登记在 `docs/EVIDENCE.md`，缺陷在 `docs/DEFECTS.md`。
> **冻结记录**：维度/权重/关键标记于 2026-09-16 控制面初始化（`ITERATION_STATE.json` revision 1）时冻结；变更须写入状态文件 `change_log`。

## A. 基线与治理

| # | 需求 | 维度 | 权重 | 关键 | 优先级 | 实现位置 | 验证方式 | 证据 | 状态 | 阻塞 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A1 | 基线可运行：analyze 0、test 全绿（HEAD） | tests | 3 | 否 | P0 | 全仓 | HEAD 干净导出实跑 | `D:\tmp\zr\baseline_head_16a7d8e.log`（574/574）；E-03 | PASS | — |
| A2 | 用户未提交改动被保留 | operations | 1 | 否 | P0 | 工作区 5 文件 | `git status` 前后一致 | E-01；控制面初始化时复核（diff 指纹 286670fc） | PASS | — |
| A3 | 秘密不在仓库 | security | 3 | 是 | P0 | `.gitignore` / `git ls-files` | 扫描无跟踪的 key/jks/env；字面量扫描 | E-02；E-17（g-secrets.log） | PASS | — |
| A4 | 签名密钥接触面事件有处置记录（ADR-003 拍板并记入 DECISIONS） | security | 3 | 是 | P0 | `docs/adr/ADR-003` | 用户对 ADR 拍板并记录 | — | BLOCKED | BL-001 用户决策 |
| A5 | 治理文档 + 工作记忆文件存在且无占位符 | docs | 3 | 否 | P1 | `docs/PROJECT_*`、`docs/DEFECTS.md`、`docs/EVIDENCE.md`、`docs/DECISIONS.md`、`docs/adr/`、`docs/continuous-iteration/` | 文件存在、UTF-8、无未填的输入卡占位符 | E-04/E-09；E-17 | PASS | — |
| A6 | ADR-001～005 存在且状态与实际一致 | docs | 2 | 否 | P2 | `docs/adr/` | 状态行核对 | E-09；E-17（ADR-001 已采纳，002～005 待拍板/取证） | PASS | — |

## B. 核心纵向闭环（导入 → 门禁 → 会话 → 事件 → 提醒 → 跳转 → 解决 → 重连仍正确）

| # | 需求 | 维度 | 权重 | 关键 | 优先级 | 实现位置 | 验证方式 | 证据 | 状态 | 阻塞 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| B1 | 导入去重/命名/替换/删除原子且并发安全 | core | 2 | 否 | P1 | `device_store.dart`、`DeviceListNotifier` | `device_command_serial_test` 5/5、`device_store_chaos_test` | 台账 build 24 | PASS | — |
| B2 | 门禁覆盖全部路由；恢复二选一；双写失败不放行 | core | 3 | 是 | P1 | `main.dart`、`security_lock.dart` | `biometric_gate_test` 16/16（生产拓扑） | 台账 build 24 | PASS | — |
| B3 | 桥消息全链字节预算；重复片差量回收 | core | 2 | 否 | P1 | `bridge_message_pipeline.dart`、注入脚本 | JS 门 49/49；`r13_postfix_probe` 8/8 | 台账 build 26；E-06 | PASS | — |
| B4 | **同任务多条交互：解决一条不清红点，全清才落** | core | 3 | 是 | P1 | `event_feed.dart`、`StateDiffer` | `event_feed_test` R-19 组（9 用例）、`event_parser_test` R-19 组 | E-05/E-10；CR 不变量 1 PASS | PASS | — |
| B5 | **缺 summary 的扁平行不产生假 resolved（同投递与跨投递）** | core | 3 | 是 | P1 | `StateDiffer.apply`、`TaskIndexExtractor` | `event_parser_test` 合并组 4 + 跨投递组 6 | E-05/E-10；CR 不变量 2/3 PASS | PASS | — |
| B6 | resolved 有剩余时不撤系统通知 | core | 2 | 是 | P1 | `webview_sync.dart` | 代码路径 + CR 核对 + 通知通道探针 | CR 不变量 1 PASS（`(pendingTotal ?? 0) <= 0` 才撤）；E-13 | PASS | — |
| B6a | 观察面数值对抗：负数 / Infinity / 小数 / 字符串 / 超大整数不抛、不污染、不回绕 | core | 2 | 否 | P2 | `_finiteInt`/`_pendingCount`/`kMaxPendingCount`；`ingestMessage` 兜底 | `event_parser_test` "R-19 复审"组 4 用例 | E-10；TE 对抗 10/10（E-13） | PASS | — |
| B6b | dedupe 冲突保留权威计数；inherit 保留 preview | core | 1 | 否 | P2 | `EventParser.dedupe`、`inheritPendingFrom` | 同组 3 用例 | E-10 | PASS | — |
| B7 | 跨消息幂等：同键窗口内只提醒一次；resolved 后新一轮照常提醒 | core | 2 | 否 | P1 | `EventDedupeGate` | 现有测试 | 已有 | PASS | — |
| B8 | 通知点击回到对应设备与会话（代码路径 + 模拟器证据；真机回跳归 D3） | core | 2 | 否 | P1 | `session_jump.dart`、`NotificationTap` | 现有测试（跳转确认 attemptId/结果/失败原因） | 已有；真机验收归 D3 | PARTIAL | BL-003 用户设备 |
| B9 | 重连/重放不重复提醒、不丢待处理 | core | 2 | 否 | P1 | `StateDiffer.pruneOnSnapshot`、去重闸门 | 现有测试 | 已有 | PASS | — |

## C. 安全与供应链

| # | 需求 | 维度 | 权重 | 关键 | 优先级 | 实现位置 | 验证方式 | 证据 | 状态 | 阻塞 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | 桥回调：文档信任 + 主 frame 令牌 | security | 3 | 是 | P1 | `_bridgeAllowed` | `BridgeAuthPolicy` 单测、安全不变量 24/24 | 已有 | PASS | — |
| C2a | 子 frame 取证计数器：非主 frame 导航计数 + 诊断页可见 + 测试（ADR-002 步骤 1） | security | 1 | 否 | P1 | `official_remote_page.dart`（`shouldOverrideUrlLoading`）+ `state/subframe_stats.dart` | 单元/注入测试 + 计数断言 | E-19；零上下文审计×2（首轮 1P2+4P3 全修，复审 5/5 PASS） | PASS | — |
| C2b | 子 frame 运行时证据归档 + ADR-002 路线拍板（A/B/C/D） | security | 1 | 否 | P1 | 真机/soak 数据 + `docs/DECISIONS.md` 决策记录 | 数据归档 + 决策记录 | — | BLOCKED | BL-007 用户设备与决策 |
| C3 | 出站 URL 仅 https 白名单、逐跳校验、拒私网 | security | 3 | 否 | P1 | `outbound_url_policy.dart` | `update_service_test` 出站策略组 | 基线 574 内 | PASS | — |
| C4 | 依赖漏洞：OSV fail-closed，公网实扫 | security | 2 | 否 | P2 | `check-dependency-advisories.py` | 实跑退出码与摘要 | E-08；E-17（237 组件、0 达 high、exit 0） | PASS | — |
| C5 | 发布产物四重绑定可复核 | security | 2 | 否 | P1 | `verify-release-artifacts.py` | 脚本自测 20/20；b5 产物 OK | 台账；E-17（20/20） | PASS | — |
| C6 | 日志/诊断包脱敏 | security | 2 | 否 | P1 | `structured_log.dart`、`diagnostics_bundle.dart` | `log_redactor_test` | 基线内 | PASS | — |
| C7 | 每设备 WebView 站点数据隔离 | security | 2 | 否 | P2 | 待定（ADR-004） | — | — | BLOCKED | BL-004 产品决策 |

## D. 运维、发布与真机

| # | 需求 | 维度 | 权重 | 关键 | 优先级 | 实现位置 | 验证方式 | 证据 | 状态 | 阻塞 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| D1 | CI 三条工作流在真实 GitHub 实跑通过 | operations | 3 | 是 | P1 | `.github/workflows/*` | Actions 运行记录 | — | BLOCKED | BL-002 GitHub 账号 |
| D2 | tag 策略（`v1.0.0` 已占用）落定并记录 | operations | 2 | 否 | P1 | 发布流程 | 决策记录 | DEC-18（沿用 v1.0.0、内部 versionCode 递增）；E-51 | PASS | — |
| D3 | 真机矩阵 / 48h soak / TalkBack / 实体生物识别 | operations | 3 | 是 | P1 | — | 按 RELEASE-CHECKLIST 归档 | — | BLOCKED | BL-003 用户设备 |
| D4 | 生成文件陷阱有防护说明 | operations | 1 | 否 | P2 | 台账 + `EXECUTION_PROMPT` | 执行者遵守备份/恢复 | E-15/DEC-02；控制面协议（导出跑测试） | PASS | — |
| D5 | 无凭据机型擦除失败出口 | operations | 2 | 否 | P2 | 待定（ADR-005） | — | — | BLOCKED | BL-005 产品决策 |

## E. 独立审计闭环

| # | 需求 | 维度 | 权重 | 关键 | 优先级 | 验证方式 | 证据 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | 零上下文架构/核心正确性审计（针对当轮改动） | docs | 2 | 否 | P1 | 只读代理报告 → 缺陷表 → 修复 → 复审 | `docs/audits/2026-09-16-code-review-R19.md`（可以合并，8/8 PASS） | PASS |
| E2 | 零上下文安全审计 | security | 2 | 否 | P1 | 同上 | `docs/audits/2026-09-16-security-audit-R19.md`（READY） | PASS |
| E3 | 独立验收（test-engineer）跑全量并核对关键验收 | tests | 2 | 否 | P1 | pass/fail + 证据 | `docs/audits/2026-09-16-acceptance-R19.md`（PASS，604/604，对抗 10/10） | PASS |
| E4 | 审计发现全部进入 `DEFECTS.md` 并闭环（P0/P1 不降级） | tests | 2 | 否 | P1 | 缺陷表状态 | D-01～D-16：10 closed / 3 documented / 2 open(P3) / 1 blocked(P0, D-16) | PASS |
| E5 | 返修批经**新的**零上下文代理复审 | docs | 2 | 否 | P1 | 复审报告 | `docs/audits/2026-09-16-re-review-R19-fixes.md`（可以合并，A–H PASS；3 P3 已修、1 登记 D-15） | PASS |

## F. 测试证据（维度口径补充）

| # | 需求 | 维度 | 权重 | 关键 | 优先级 | 验证方式 | 证据 | 状态 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T-01 | 注入脚本契约门在当前检查点通过（49 断言） | tests | 2 | 否 | P1 | `node scripts/check_injected_js.mjs` | E-06；E-17（49/49，exit 0） | PASS |
| T-02 | 发布脚本自测全过（5 脚本 87 例） | tests | 2 | 否 | P1 | 各脚本 `--self-test` | E-17（11+25+9+20+22=87/87） | PASS |
| T-03 | R-19 全部 P1/P2 修复有回归测试钉住（含 1e999/负数/回绕/dedupe/通知撤销条件） | tests | 3 | 否 | P1 | `event_feed_test` / `event_parser_test` 对应用例；"回退即失败"机制 | E-05/E-10/E-15；CR2 G 项 PASS | PASS |

## 计分（与 `ITERATION_STATE.json` 同频）

| 维度 | 权重积 possible | earned | 占比 | 档位下限（release_candidate） |
| --- | ---: | ---: | ---: | ---: |
| core | 24 | 23 | 95.8% | ≥80% |
| security | 24 | 18 | 75.0% | ≥80% |
| tests | 14 | 14 | 100% | ≥75% |
| operations | 12 | 2 | 16.7% | ≥70% |
| docs | 9 | 9 | 100% | ≥70% |
| **总分** |  |  | **80 / 100** | 目标 ≥85 |

> 计分口径：条目贡献 = 维度权重 ×（该维度 earned / possible）；PASS 记满权重，PARTIAL 按半权重折算（B8：2×½=1），OPEN/BLOCKED/FAIL 记 0，不从分母删除。
> ITERATION 1（2026-09-17）：C2a 落地转 PASS（security 17→18），其余口径不变；治理变更记录于状态文件 `change_log`。
