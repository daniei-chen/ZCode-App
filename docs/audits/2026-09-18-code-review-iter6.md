# 代码评审：ITERATION 6 批次（打开页面静默刷新，W-017）

- **日期**：2026-09-18
- **评审方式**：零上下文 code-reviewer 子代理（新代理，与 iter4/iter5 评审员不重叠）
- **覆盖标签**：DIFF_CORRECTNESS + BOUNDARY_CONTRACT（T3 已 DONE，本轮维持双标签并强化状态机交互审查）
- **批次动因**：用户直接反馈"每次打开页面静默刷新，否则半天都是缓存"
- **评审对象**：`D:\tmp\zr\iter6_batch.patch`（对 cp-5 基线导出；`page_refresh_policy.dart` 新、`official_remote_page.dart` 三处、测试+语料）
- **门禁（评审前）**：`gates.sh i6 --osv --strict-state` 11 道门 PASS / test 663/663 / 变异 3/3（mutcov 门首跑抓到第三用例无变异后补齐）

## 方案

页面常驻 IndexedStack（切 tab/后台不销毁）→ 官方 SPA 无可见性重取 → 回来是几小时前画面。修复：控制器新增遮盖观察者（仅值变化回调）；页面记录不可见起点，重新可见/回前台/切到本设备时，由纯策略 `PageRefreshPolicy`（不可见 ≥60s 且当前页且无在途/错误）判定走既有 `_reload()`（全新加载 + 既有加载盖板），记 `webviewSilentReload reason=stale_on_visible`。

## 首轮发现

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| F-1 | **P1** | 揭启动器盖板是**全体**控制器解盖：我的守卫只看自己 covered，N 台设备会同时整页重载 N 次（网络/性能回归 + 隐藏页状态无谓丢弃 + 日志放大 N 倍） | **已修**：守卫收进纯策略 `!isCurrentDevice → false` 且调用方保留起点；页面用 deviceList+activeTab 判定 |
| F-2 | P2 | 冷启动落在启动器时初始 cover 事件先于观察者挂载，首次揭盖永不刷新 | **已修**：attach 后回放 `covered ? _onCoverChanged(true)`（initState + didUpdateWidget） |
| F-3 | P2 | 启动器已隐藏时经通知深链切设备无 covered 事件，目标页不刷新 | **已修**：build 里 `ref.listen(activeTabProvider)` 切到本设备 post-frame 判定 |
| F-4 | P3 | 揭盖瞬间在途加载会清 `_hiddenSince` 跳过本次——核实为**有意且更安全**（保旧时间戳会导致刚加载完又被无谓重载） | 补注释说明"清空是有意的"+ 反向理由 |
| F-5 | P3 | 生命周期口径（inactive 不算隐藏）核实正确 | — |
| F-6 | P3 | 控制器变化检测/守卫零测试 | **已修**：控制器单测 3 条 + 变异 4 条（同值/触发/detach），coverage-files +2 |
| F-7 | P3 | 壁钟取时长受时间跳变影响（无害） | 保留，已论证 |

## 复核

见 `docs/audits/2026-09-18-re-review-iter6-fixes.md`。

## 复核后门禁

`gates.sh i6 --osv --strict-state` 11 道门 PASS / test **668/668**（663+5）/ 变异 iter6 语料 **8/8 caught** / coverage 两文件 0 未覆盖。
