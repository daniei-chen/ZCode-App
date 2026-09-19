# 审计：UI 层全量 + 入口/锁屏流（ITERATION 8 · R2）

- **日期**：2026-09-18/19
- **审计方式**：零上下文 code-reviewer 子代理（只读；DIFF_CORRECTNESS + RESILIENCE；settings_page 980 行全文、diagnostics_page 421 行全文、update_download_dialog 409 行全文、main.dart 锁屏流逐段、manage_page/app_shell 交互边界）
- **批次动因**：用户要求"继续审计，超级详细"——补齐此前未深审的最后一块

## 总评

**阻断项：无**（无 P0/P1）。锁屏门 fail-closed、擦除事务、深链冷启动时序（bind 先于 postFrame 消费、锁定期间 payload 落 `_pending`、解锁后消费）均核实正确；全部 `await` 后 context/mounted 使用逐点核对；设置开关视觉状态单一来源；IconButton 全有 tooltip；lib/ui 无硬编码中文直接量。**有条件通过**：2 个 P2 同属"200% 字体可达性"。

## 发现与处置

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| U-1 | **P2** | 更新下载对话框不可滚动 + `barrierDismissible: false`：200% 字体 + 小屏下底部"下载/安装"主按钮被裁切且不可达，更新流程死路 | **已修**：内容包 `SingleChildScrollView`（padding 迁移到滚动视图）；source-pin + 变异 |
| U-2 | **P2** | 设置行定高 64dp：200% 字体折行标题被垂直裁切，12 处行全覆盖通知/电池/安全/更新 | **已修**：全部 `SizedBox(height:)` → `ConstrainedBox(minHeight:)`（正则批量 + 逐处核对）；source-pin（禁止残留定高形态）+ 变异 |
| U-3 | P3 | 通知偏好启动加载无兜底：存储损坏 → unhandled zone error | **已修**：`_load().catchError` + NT504 留痕；source-pin + 变异 |
| U-4 | P3 | 设置页三处对话框返回后直接用 ref，无 mounted 保护 | **已修**：三处补 `if (!context.mounted) return;` |
| U-5 | P3 | 电池行状态未加载时可点击，过早拉起系统授权 | **已修**：`_ignored == null` 时不可点 |
| U-6 | P3 | 诊断页版本号读取失败永久显示"…"，诊断包静默带空版本 | **已修（最小）**：失败时置 `?` 占位；重试入口 → 候选 W-022 |
| U-7 | P3 | 扫码 errorBuilder 在 build 期做副作用且持续故障重复记日志 | **已修**：按错误码去重；source-pin + 变异 |

观察（登记不修）：O-1 未知事件兜底正文硬编码中文（应用强制 zh，暂无害）；O-2 锁定期 lifecycle 失联自洽；O-3 缺陷编号双体系可追溯；O-4 缺 iOS 复位分支用例；O-5 更新提示重复方向可接受。

## 复核方式

修复均为审计处方原文 + 机器验证：source-pin 测试 4 条（`test/ui_hardening_test.dart`，`iter8.json` 4 条变异全部 caught——含 U-2 变异按指纹行定位唯一性修正）+ W-019 行为变异 caught；`gates.sh i8 --osv --strict-state` 11 道门 PASS / test **683/683**。审计发现的测试边界抖动（D-20260919-01：启动器"设置"入口位于 600dp 视口底边导致 tap 命中不稳定）已按高视口方案修复并登记。

## 附带发现（iter7 遗留修复中的两处，本轮一并验证）

- W-019 落地：`loadAllWithStatus` 增加孤儿 warmup 键清扫（remove 防抖写入残留），行为测试 + 变异。
- iter7 R-2 的 catch 内二次抛（复审 N-3）：AppLog 留痕 + 默认值兜底；id_mismatch 隔离点补同款留痕（复审 N-4）。
