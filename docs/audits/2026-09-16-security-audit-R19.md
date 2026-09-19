# 零上下文安全审计报告 — R-19 待处理交互按计数记账（2026-09-16）

> 审计代理：security-auditor（零历史、只读）。审计对象：`D:\AI\zcode\ZCode App` @ HEAD `16a7d8e` 的未提交改动（5 文件）+ 8 个未跟踪 docs。
> 方法：全量 `git diff` 审读、桥消息解析链路逐层核对、隔离 Dart 探针实测（`D:\tmp\zr\audit_verify\jsonprobe\`，未触碰真实仓库）、`git ls-files`/`git grep` 秘密扫描、文档泄露扫描。
> 结论：**READY**（无阻断项）。返修状态见文末。

## 总评

风险等级：低。R-19 改动未引入新的可利用信任面：新增写入路径全部有 `> 0` 正数门卫，负数/非 int/NaN 均无法污染 `pendingByTask`；未发现 P0/P1。审计过程中实测确认了一个**先于本轮存在**的解析健壮性问题（P2-1），本轮加重了对这些计数的依赖，故列入范围。

## 发现清单

### P0 / P1

无。

### P2

- **[P2-1] 页面可控 JSON 数值 `1e999` 解析为 `Infinity` 后 `.toInt()` 抛 `UnsupportedError`，可致整帧观察处理中断**（先于本轮存在）— `event_observer.dart` `TaskIndexExtractor._stateOf`/`intFromMaps`、`SessionStateExtractor._stateOf` 时间戳
  - 实测：`jsonDecode('{"p": 1e999}')` → `double Infinity, isNum true` → `toInt()` 抛 `Unsupported operation: Infinity or NaN toInt`。
  - 调用链无兜底：`webview_sync.dart ingestMessage` 仅对 `decode` 有 try/catch；`parseRoot`→`_stateOf`、`_stateDiffer.apply` 裸奔；JS handler 回调无 try/catch。
  - 影响：一帧脏数据使该帧后续全部处理（索引更新、差分、红点、通知）中断；持续注入则观察面持续失明。
  - 修复建议：`is num && isFinite` 门卫 + 值域 clamp；`ingestMessage` 外层 try/catch 走 `bridgeMessageDropped`（BR202）留痕。

### P3

- **[P3-1] 负数计数可通过 `is int` 门卫**，resolved 判定（`== 0`）失效、红点滞留 — 建议 clamp 负数 → 0。
- **[P3-2] `pendingTotal` 求和可 64 位回绕为负**（本轮新增代码），触发 `webview_sync.dart` 误撤系统通知 — 建议单计数封顶后求和。
- **[P3-3] 新增测试未覆盖恶意值域**（负数 / `1e999` / 超大整数 / 字符串数字）。
- **[P3-4] 先存观察：`EventDedupeGate` 键含 summary 文本，轮换 summary 可制造 0→1 振荡重复提醒**；本轮未改变该行为，已有前台抑制、4 MiB 帧上限、徽标 99+ 封顶兜底。

## 已检查未发现问题的项

1. 事件计数写入路径：`event_feed.dart` 两条写入路径均有 `total != null && total > 0` 门卫；非 int 在提取层被拒；NaN 字面量在 `jsonDecode` 层即 `FormatException`；`hasPendingSummary` 只做判型；`copyWith` 正确保留 `pendingTotal`；`pendingByTask` 无数值型 UI 消费。
2. 秘密卫生：`git ls-files` 无 key.properties / *.jks / *.keystore / .env / *.pem / *.p12 命中；工作区实际存在 `android/key.properties` 与 `android/zcode-app-release.jks`（未读内容），被 `android/.gitignore` 覆盖且 `git status --ignored` 为忽略态；凭据字面量 10 处命中全部为测试夹具假值；8 个新增 docs 无秘密形态字符串或带 token/sid/hash 的控制链接。
3. 出站请求策略回归：`outbound_url_policy.dart isAllowed` 仍为 https + 4 个 GitHub 官方域白名单 + 拒 userinfo + 仅 443 + `isPublicEndpoint`；`resolveRedirect` 每跳重过；`update_service.dart` 手动跟随（`followRedirects=false`、`maxRedirects=5`）完好。已知边界：DNS pinning 未覆盖（与上轮一致）。
4. 日志脱敏与诊断包边界：`pendingTotal`/`pendingByTask` 在日志、诊断包、通知代码中零引用。
5. 依赖漏洞：`D:\tmp\zr\osv_20260916.log` 存在：OSV 退出码 0，237 组件无达 high 阈值的未豁免 advisory；`git diff 7ce0485..HEAD -- pubspec.lock` 为空。
6. 安全例外清单：`scripts/security-exceptions.json` 的 `exceptions` 为空数组。
7. 工具缺失：本机无 gitleaks，以 git 层面手动核查替代。

## 最终结论

**READY**。P2-1 建议纳入下一轮修复并补恶意值测试。

---

## 返修状态（主代理记录，2026-09-16）

| 发现 | 处置 | 证据 |
| --- | --- | --- |
| P2-1 Infinity `toInt()` 中断整帧 | **已修**：`_finiteInt`/`_pendingCount` 辅助函数（只认有限值 / 非负 int）；所有 `toInt()` 站点改用；`ingestMessage` 外层 try/catch → `AppLog.failure(LogEvent.bridgeMessageDropped, reason: ingest_exception)` | `event_parser_test.dart` "1e999（Infinity）/ 小数 / 字符串计数都不采信且不抛异常" |
| P3-1 负数 | **已修**：负数 → 0 | "负数计数按 0 处理且仍算权威" |
| P3-2 回绕 | **已修**：单计数封顶 `kMaxPendingCount = 1024` | "超大计数封顶 kMaxPendingCount：pendingTotal 求和不回绕为负" |
| P3-3 测试缺口 | **已补** | 同上三条 + 任务索引扁平计数字段用例 |
| P3-4 dedupe 振荡 | **记录为先存已知项**（DEFECTS D-20260916-10），本轮不改 | — |

返修后：analyze 0，`flutter test` 604/604（E-10）。
