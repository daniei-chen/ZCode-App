# 安全返修复核：ITERATION 5（S-1..S-9 + N-1..N-5）

- **日期**：2026-09-18
- **评审方式**：首轮同一 security-auditor 子代理续会话复核（只读；重跑 `check_injected_js.mjs` 49/49、语料结构静态验证 10/10→14/14）
- **前置报告**：`docs/audits/2026-09-18-security-r3.md`

## 首轮复核结论

S-1/S-3/S-4/S-6/S-7/S-9 PASS；**S-2 FAIL**（守卫只接了 zrEvents，同预算的 zrWs 通道仍是裸 `jsonDecode`——N-1 P2 阻断）；S-5 PASS 但残留 N-2（`_ensureBridgeToken` 返回手势退避循环无守卫注入令牌，台账里"死门"论断对 back 路径不成立）；S-1 残留 N-3（`replaceTasks` 快照未封顶）；S-7 残留 N-5（`lastSessionTitle` UI 通道无截断）；观察 N-4（其余解析面统一收敛建议）、N-6（驱逐可能逐出 pinned）、N-7（`_clip` 切代理对）。

## 残留处置（第二轮返修）

| # | 处置 | 回归/变异 |
|---|---|---|
| N-1（P2） | `ingestWebSocketEvent` 改走 `BridgeMessagePipeline.decode`（zrWs 与 zrEvents 同一深度预扫）；`webview_sync.dart` 不再有任何 `jsonDecode` | 源码断言"zrWs 通道不再有裸 jsonDecode" + 变异 `iter5-zrws-bare-jsondecode` |
| N-2（P3） | 守卫下沉进 `_injectBridgeToken` 开头单点收口（覆盖 load 事件、返回手势退避、初始化全部调用方） | 源码断言"守卫在函数体内" + 变异 `iter5-inject-guard-removed` |
| N-3（P3） | `replaceTasks` 末尾同样 `_evictOverflow` | 测试 7000 条快照 → 4375 + 变异 `iter5-replace-tasks-unbounded` |
| N-5（P3） | `EventFeedNotifier` 存 `lastSessionTitle` 前按通知通道口径截断（120+省略号） | 测试 2 MB 标题 → 121 + 变异 `iter5-feed-title-unbounded` |
| N-4/N-6/N-7 | 观察——N-4"解析面统一收敛"作为后续候选方向记录（W-016 同类）；N-6/N-7 记录不修（洪泛下 UX 代价/外观） | — |

## 复核后门禁

- `gates.sh i5 --osv --strict-state`：**11 道门全 PASS**（analyze 0 / test **660/660** / JS 49 / doc-drift 6 / 秘密 0 / 自测 87 / state / mutcov / OSV BLOCKED）
- 变异 iter5 语料：**12/12 caught + 2 exempt (declared)**
- 首跑插曲：新测试漏 import 导致 analyze FAIL 1 轮、webview_sync 删掉最后一个 `jsonDecode` 后 `dart:convert` 未用告警 1 轮——均由门禁当场抓住并修复（门禁有效的又一例证）

## 最终结论

**可以合并。** S-1..S-9 全部闭环（S-8 显式候选化）；N-1..N-5 残留全部收口；本轮发现整体降级为纵深防御项。总体评级：**中低**。
