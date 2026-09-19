# 审计：状态管理与服务面（ITERATION 7 · R2）+ 独立验收抽样（W-010）

- **日期**：2026-09-18
- **两个独立零上下文审计并行执行**：① code-reviewer（RESILIENCE + BOUNDARY_CONTRACT，状态管理/系统服务面——此前从未深审）；② test-engineer（W-010 独立验收：抽样 11 条 PASS 验收项，回退即失败复核）
- **门禁（审计时）**：`gates.sh i6 --osv --strict-state` 11 道门 PASS / test 668/668

## 一、服务面审计（代码评审）

**总评：条件通过（B+），无 P0/P1。** 读路径 fail-closed 设计（unavailable ≠ 空库、零写入、写队列 + epoch、擦除四步记账）质量高；短板集中在**写路径失败的用户可见性**。

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| R-1 | **P2** | 设备写命令失败全链路静默（表单/改链/改名/删除 5 处裸 await）；**扫码导入失败后 `_navigating` 永不复位 → 扫码器死锁** | **已修**：5+2 处 try/catch + `SnackBar(l10n.operationFailed)`（新增 l10n 键）+ 扫码失败分支显式复位 `_navigating`；widget 级测试豁免显式登记（W-018） |
| R-2 | **P2** | 设置类写入"乐观更新"：UI 先改、磁盘写失败无提示无回滚，重启回滚；Future 被丢弃成 unhandled | **已修**：notification_prefs / startup_target 改持久化优先，失败回读/回退 + DS/NT 留痕；source-pin 测试 + 交换变异 caught（SharedPreferences 插件通道单测不可控 → 沿用仓库 source-invariant 风格） |
| R-3 | **P2** | 损坏设备记录被隔离零留痕（repaired/skippedRecords 无消费者），用户视角"设备凭空消失" | **已修**：4 个隔离点记 `DS704`（record_quarantined / orphan_quarantined / id_mismatch + shortId，不记内容）；行为测试 + 变异 caught；诊断包暴露计数 → 候选 W-018 |
| R-4 | P3 | `remove` 不作废在途 warmup 写入（epoch 只护 clearAll）→ 已删设备预热脚本可残留 | 候选 W-019 |
| R-5 | P3 | 被代际作废的命令以"成功"完成（UI 可见未持久化设备） | 候选 W-020 |
| R-6 | P3 | 删除设备后 bridgeHealth 残留（诊断包幽灵行） | **已修** + 行为测试 + 变异 |
| R-7 | P3 | "多设备"提示 `== 5` 永不再触发 | **已修** `>= 5` + 注释钉语义 |
| R-8 | P3 | 洪泛驱逐可挤掉 pinned 会话 | **已修**：两轮驱逐（pinned 最后 + 兜底保有界）；测试 2000 pinned 全存活 + 变异 caught |
| R-9 | P3 | `ingestSeen` 256 KiB 上限按 UTF-16 计（CJK 放行 2-3 倍） | **已修**：UTF-8 字节计（与 acceptString 同口径）；"UTF-16 过 / UTF-8 超"双向用例 + 变异 caught |
| R-10 | P3 | 卫生合并（bridge_health 死条件、_clip 切代理对、root_tabs 文件名、alertMode 脏值） | 候选 W-021 |

观察项（无生产复现路径）：warmup load TOCTOU、AppSettings fail-open、BiometricGate 壁钟（建议 monotonic）、_shouldRecord 注释措辞。

## 二、独立验收抽样（test-engineer，W-010）

**11 项抽样：8 项 PASS 确认（附回退即失败证据）、3 项有缺口**；报告与全部工件由 TE 落库。

- **确认 PASS**：B6a（数值对抗 4 向变异全红）、B7（幂等两向）、T-01（注入门 49/49，破坏脚本即 13 断言连锁失败——门非空转）、A6（ADR 状态与实现/阻塞一致）、B1（并发安全由 Notifier 命令队列钉住）、T-02（自测 87/87 含负例）、C3（附注）、B8（矩阵 PARTIAL 定级准确，无虚报）。
- **C2a → 建议降 PARTIAL**：探针实锤"hook 判定改恒 true → 全部测试仍绿"（接线层零守卫）。→ **iter7 已补**：security_invariants 源码钉 + 变异 `iter7-c2a-hook-constant-true` caught；行为级仍归 C2b 真机。
- **T-03 声明部分不实**：B6 撤销条件此前全仓无测试引用。→ **TE 已当场补** `test/acceptance/b6_notification_withdraw_guard_test.dart`（3/3，两方向变异均红）。
- **C3 盲区**：`http://github.com:443/x`（端口掩盖协议）→ **已补用例** + 变异 caught。
- 新增工件：`test/acceptance/b6_notification_withdraw_guard_test.dart`、`audit_mutations_*.json` ×3（探针语料留存为缺口证据）。

## 三、复核（返修后）

- 逐项 PASS；**新发现 N-1（P2·流程）**：W-018..W-021 候选登记声明未落地 → **本轮记账补录**（引 iter3 N-1 复发，LESSONS L-17 强化执行）。N-2/N-3/N-4（P3：注释漂移、_load 二次抛、id_mismatch 留痕）→ **已当场收口**。
- 复核后门禁：`gates.sh i7 --osv --strict-state` 11 道门 PASS / test **678/678** / 变异 iter7 语料 **8/8 caught + 1 exempt**。

## 结论

**可以合并（附条件已满足）**。总体评级维持中低；安全/健壮性 open 缺陷继续为 0。
