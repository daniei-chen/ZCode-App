# 返修复核：ITERATION 6（静默刷新 F-1..F-8）

- **日期**：2026-09-18
- **评审方式**：首轮同一 code-reviewer 子代理续会话复核（只读）
- **前置报告**：`docs/audits/2026-09-18-code-review-iter6.md`

## 首轮复核结论

F-1（P1 揭盖全体解盖→收敛当前页）/F-2（初始 cover 回放）/F-3（应用内切设备监听）/F-4（清空语义注释）/F-6（控制器契约测试+变异）**全部核实通过**；**新发现 F-8（P2）**：收敛重构时把 covered 早退守卫弄丢了，注释与实现相悖——launcher 覆盖下的 resume 会在用户没看页面时后台整页重载。

## F-8 处置

按复核处方**原句恢复**一行守卫：`_maybeSilentRefresh` 顶部、读/清 `_hiddenSince` 之前 `if (widget.backController?.covered ?? false) return;`，注释写明场景（launcher 覆盖下的 resume 推迟到真正揭盖判定）。复核原文："已验证不影响 F-1/F-3 路径……与 :1045 注释语义完全一致，无需改文档。"

顺带：`mutate.py` 文档补 `only` 字段语义说明（复核标注"待确认"项）。

## 复核后门禁

- `gates.sh i6 --osv --strict-state`：**11 道门全 PASS** / analyze 0 / test **668/668** / mutcov PASS / OSV BLOCKED
- 变异 iter6 语料：**8/8 caught**（`evidence/i6-mutations.log`）；coverage 两文件 0 未覆盖

## 最终结论

**可以合并。** F-1..F-8 全部闭环；复核对修复质量的原话："守卫收进纯策略、保留语义顺序正确、测试-变异一一对应、门禁证据链完整"。
