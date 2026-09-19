# 独立评审：iter8+iter9 合并批（ITERATION 10）

- **日期**：2026-09-19
- **评审方式**：零上下文 code-reviewer 子代理（新代理，与 iter4/5/7/8 评审员不重叠；对 cp-7 基线的 13 文件合并 patch + 工作树实读）
- **覆盖标签**：DIFF_CORRECTNESS + BOUNDARY_CONTRACT
- **门禁**：`gates.sh i10 --osv --strict-state` 11 道门 PASS / test **694/694** / 变异全语料 69+6

## 首轮发现（8 条，无 P0/P1）

| # | 级别 | 问题 | 处置 |
|---|---|---|---|
| F-1 | **P2** | reorder 的 Future 被 ReorderCallback(void) 丢弃，异常无兜底——DeviceStoreSuperseded 契约变更遗留缺口；注释"均已兜底"与事实不符 | **已修**：catchError + SnackBar + pin 测试 + 变异；注释改写为如实清单（N-3） |
| F-2 | **P2** | 擦除事务漏清 deviceConnectivityProvider；clear() 死代码 | **已修**：step1 clear + coveredProviders + pin 测试 + 变异 |
| F-3 | P3 | 双 clearAll 并发误报失败 | **已修**：`_serialized` 增加 `supersedeable` 通道，clearAll 传 false（内层代际检查表达作废语义） |
| F-4 | P3 | warmup 定时器 catch 把"被擦除作废"（预期）记成 failure；首轮修复落在错误 catch（forget），复核 N-1 抓出 | **已修**：双 catch（定时器 + forget）均补 superseded → info 分支 |
| F-5 | P3 | 探测可达复用 statusLive 文案（语义越界：探测只证网络可达不证会话活） | **已修**：新增 statusReachable 文案，switch guard 区分 |
| F-6 | P3 | 探测轮无 in-flight 去重（可选） | 候选 W-024 |
| F-7 | P3 | DEFECTS 重复行 | **已修** |
| F-8 | P3 | manage_page Stack 缩进 | 候选 W-024（定向 format） |

## 复核

- 第一轮复核（返修后）：6 PASS + N-1（F-4 修复落在错误 catch，必修）+ N-2/N-3（台账/注释声明未落盘——L-17/L-24 同类失败模式）。
- 最终裁定（N-1/N-2/N-3 落地后）：**可以合并**。"无未决 P0-P2。"

## 诚实记录（L-24）

首轮返修时 pin 测试的 Edit 因 file-modified 失败后未重试，导致变异首跑 0/2（测试不存在，门禁全绿是假象）——被变异工具自己抓出。python replace 无 assert 静默 no-op（注释改写未落盘）同轮实锤。两条均入 LESSONS L-24。
