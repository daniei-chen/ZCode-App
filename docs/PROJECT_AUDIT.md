# PROJECT_AUDIT — ZCode App 项目审计

> 审计日期：2026-09-16 · 基线提交：`release/v1.0.0 @ 16a7d8e`（代码同交付版 build 26 `7ce0485`，其后仅台账/文档变动）
> 审计方式：只读接管 + 干净导出实跑基线 + 对照既有三轮审计（b3/b4/b5，R-02～R-19）与 F01–F26 缺陷总表逐项核对开放状态。
> 本文只记录**当前仍开放**的问题与本轮新发现；已关闭项的证据见 `docs/PLAN-v1.1.0.md`（滚动台账）与 `docs/releases/v1.0.0.md`。

## 0. 诚实结论

**它是什么**：ZCode 桌面端"移动远程控制"功能的 Android 伴侣客户端（Flutter，包名 `com.zcode.app`）。原生外壳负责设备管理（扫码/链接导入、命名、排序、替换、删除）、生物识别门禁、受保护数据擦除、通知、应用内更新（断点续传 + SHA256 + 出站 URL 策略）、诊断；进入设备后由内置 WebView 加载官方远控页，原生层只做**观察**（桥消息 → 会话状态 diff → 红点/通知/跳转），不复刻协议、不复刻 UI。

**它不是什么**：不是独立远控实现，不是官方产品（非官方、MIT、上游 pjpv/zremote 改造），无自建服务端，不做 iOS，不做批量接管，不绕过 relay 单配对鉴权。

**成熟度判断**：

| 尺子 | 结论 | 依据 |
| --- | --- | --- |
| 代码与工程成熟度 | **高** | 574 个测试全绿、analyze 0；发布链 fail-closed（签名必需、manifest/sidecar/SBOM 四重绑定、插件存活门、OSV 门禁、文档防漂移）；威胁模型 T1–T12；三轮独立审计整改闭环 |
| 运行时有效性 + 证据闭环 | **中偏高，有明确缺口** | 真机矩阵/48h soak/TalkBack 未做；CI 从未在真实 GitHub 上跑过（账号受阻）；核心闭环里"待处理交互记账"存在会误清红点的语义缺陷（R-19，本轮修） |
| 治理 | **一处 P0 级待决** | 签名密钥两次接触面事件（b3 明文包、终端误输出）处置决策未定 |

**当前成熟度 = 内部发布候选**。9 小时预算内现实可达 = **生产改进版**：核心闭环记账正确性修复并经独立复审、5 项挂起决策形成 ADR（其中 3 项需用户拍板）、依赖漏洞公网实扫、四份治理文档与持久化工作记忆落地。**不可能在本轮内达到"公开生产"**：真机矩阵、soak、CI 实跑、密钥处置都依赖用户侧设备/账号/决策。

**推荐**：继续演进（不重构、不重建）。架构边界清楚、测试基础厚，重建只会丢失三轮审计积累的运行时证据。

## 1. 事实盘点

| 项 | 事实 |
| --- | --- |
| 仓库 | `D:\AI\zcode\ZCode App`，分支 `release/v1.0.0`，工作区含 5 个未提交文件（R-19 半成品，+317/−37，**审计时未经测试**，已保留） |
| 版本 | `pubspec.yaml` = `1.0.0+26`；交付 APK sha256 `7401f98c…`、versionCode 26、签名证书 `07091ffd…`、arm64-v8a |
| 工具链 | Flutter 3.47.4 stable / Dart ^3.12 / AGP 8.11 / JDK 17 / compileSdk 36 / minSdk 24 |
| 关键依赖 | flutter_inappwebview 6.1.5、mobile_scanner、flutter_secure_storage 11.1.1、local_auth、flutter_riverpod 3、flutter_local_notifications 22、url_launcher、http、crypto |
| 规模 | `lib/` 17,910 行 Dart（services 25 / state 14 / ui 8 文件）；`test/` 46 文件 574 用例；`integration_test/` 存在 |
| 原生层 | 仅 `MainActivity.kt` + 生成的 `GeneratedPluginRegistrant.java`（未跟踪、生成文件） |
| CI | `ci.yml`（analyze+test）、`ci-heavy.yml`（API 30/34 模拟器 E2E）、`release.yml`（无发布签名即失败） |
| 发布脚本 | `check-doc-drift.py`、`check-dependency-advisories.py`（OSV，CVSS v2/v3 解析，v4 未评估阻断）、`check-plugin-survival.py`、`check_injected_js.mjs`（49 断言）、`generate-release-manifest.py`+schema、`generate-sbom.py`（CycloneDX）、`verify-release-artifacts.py`、`verify-keystore-backup.sh`、`package-source.ps1` |
| 文档 | ARCHITECTURE / THREAT-MODEL / PRIVACY / COMPLIANCE / SUPPORT / RELEASE-CHECKLIST / ROADMAP / OPERATIONS-RUNBOOK / ZCODE-PROTOCOL / RELAY-PROTOCOL-VERIFIED / BENCHMARKS / PLAN-v1.1.0（滚动台账）/ releases/v1.0.0.md（build 20–26） |
| 许可证 | MIT（上游 pjpv/zremote 亦 MIT）；品牌与介绍图权利归各自所有者，README 已声明 |

## 2. 运行 / 测试基线（本次实跑）

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| `flutter analyze`（HEAD 干净导出） | **No issues found** | `D:\tmp\zr\baseline_head_16a7d8e.log` |
| `flutter test`（HEAD 干净导出） | **574/574 passed** | 同上，2026-09-16 00:04 |
| 密钥卫生 | `android/key.properties`、`android/local.properties`、`**/*.jks`、`**/*.keystore` 均在 `.gitignore` 且 `git ls-files` 无命中；字面量扫描仅命中 `scripts/check_injected_js.mjs` 的测试夹具令牌（非凭据） | 本次 `git grep` |
| 工作区改动 | 5 文件 R-19 半成品，未运行测试 | `git diff --stat` |

基线取证刻意在**临时导出目录**执行：台账记录 `flutter test` 会把未跟踪生成文件 `GeneratedPluginRegistrant.java` 重写为 debug 形态，随后本地出包会失败或产出剥插件坏包。执行者在真实工作区跑测试前必须备份该文件（见 `EXECUTION_PROMPT_9H.md` 约束）。

## 3. 开放问题表

严重度按母提示词定义：P0 数据损坏/密钥泄漏/核心不可用；P1 核心流程错误/高概率安全问题；P2 明显质量问题；P3 优化建议。

| ID | 级别 | 问题 | 证据 | 状态 / 归属 |
| --- | --- | --- | --- | --- |
| A-01 | **P0（治理）** | 发布签名密钥两次接触面事件（b3 审计包曾含明文密钥；一次终端误输出）处置决策未定。Android 更新要求同签名，轮换即切断已装用户的覆盖升级路径（或依赖 v3 签名轮换，API 28+） | `docs/PLAN-v1.1.0.md` "密钥处置决策"；b5 安全审计记录 | **阻塞：用户决策**。本轮产出 ADR-003 供拍板 |
| A-02 | P1 | **R-19 待处理交互记账**：`pendingTasks` 是任务集合，`resolved` 直接删任务键。同任务审批+输入并存时，审批解决即误清红点并撤系统通知；另发现任务索引扁平行（无 `pendingInteractionSummary`）计数缺省 0，跨投递可产生**假 resolved** 误清红点 | `lib/state/event_feed.dart`（HEAD）；`lib/services/event_observer.dart` `StateDiffer.apply`/`TaskIndexExtractor._stateOfFlat`；上游证据：`pendingInteraction.interactionId` 只标识当前浮出一条，其余仅计数 | **本轮修复**（工作区已有半成品） |
| A-03 | P1 | **R-14 / F03 残余**：桥令牌可挡跨域子 frame，但同源/srcdoc frame 可读主 frame 令牌；未设 `regexToCancelSubFramesLoading`；插件 6.1.5 不提供调用方 frame/origin 参数（需 6.2.0-beta） | `official_remote_page.dart` `_bridgeAllowed`；PLAN F03 行 | **本轮 ADR-002**：需运行时证据（官方页是否合法使用 iframe）再决定阻断；不盲目阻断 |
| A-04 | P1 | 发布链与 CI 从未在真实 GitHub 上执行（F20/F21 机制就位、证据为零）；`v1.0.0` tag 已占用且规则禁移动，tag 策略未定 | PLAN "GitHub 账号恢复后推 7ce0485 + 实跑 CI/发布链"、"注意（发布层）" | **阻塞：外部（账号）** |
| A-05 | P1 | 真机矩阵（厂商 ROM、1/2/3/5 设备并发、后台策略）、48h soak、TalkBack、实体生物识别未做；SUPPORT 只承诺可自动复核部分 | `docs/SUPPORT.md` §一/§四 | **阻塞：用户设备** |
| A-06 | P2 | 每设备 WebView 站点数据隔离未做（R-17 细化）；全部设备 WebView 常驻（F16 资源池后续） | PLAN R-17 行、F16 | **产品决策** → ADR-004 |
| A-07 | P2 | 无系统锁屏凭据机型的擦除失败出口：是否增加"显式知情确认"放行 | PLAN b5 H-2 记录 | **产品决策** → ADR-005 |
| A-08 | P2 | 同任务待处理计数 1→2 不再提醒（differ 只在 0→>0 发请求事件，依赖页面显式事件补位） | `StateDiffer.apply` | 记录为已知限制，随 R-19 成文 |
| A-09 | P2 | 公网 OSV 依赖扫描未实跑（脚本与门禁就位） | `scripts/check-dependency-advisories.py` | **本轮实跑** |
| A-10 | P2 | 版本名保持 1.0.0：已装 1.1.x 的设备在应用内看不到"更新"（内部号递增、覆盖安装不受影响） | PLAN R-07 注 | 用户已接受，记录为接受风险 |
| A-11 | P3 | 源码台账含开发机绝对路径；文档 4 处引述 `_密钥_勿入git` 字符串（无实体） | b5 安全审计低风险项 | 已评估接受 |
| A-12 | P3 | `BENCHMARKS-RESULTS-v1.0.8.md` 与 `simulated-matrix-results` 分支为模拟数据，需持续可见的"模拟"标注 | 文件名/分支名 | 已复核并加固（iter4 W-004，2026-09-18）：文件顶部加数据状态横幅（所有测量数据均为模拟器数据、APK 溯源信息为真实、真机分节为空模板、分支同为模拟）；模拟器表头加"非真机，不计入验收" |

## 4. 实现状态分层

| 层 | 内容 |
| --- | --- |
| **已实现且有运行时证据** | 门禁二选一恢复（R-02/03/04）、擦除事务 10 Provider + 磁盘 + WebView 站点数据 + 通知撤销、存储 readAll 失败不伪装空库（R-05）、Notifier 命令串行（R-06）、更新器出站策略逐跳校验/私网拒绝（R-10/11）、桥全链字节预算（R-13，JS 门 49/49）、主 frame 令牌（F03 主体）、盖板 wall-clock 计时、发布资产四重绑定、插件存活门 |
| **部分实现** | R-17 WebView 存储清单（IndexedDB 已补，per-device 隔离未做）；F16/F17 资源池与 DOM 观察面收窄（观察 allowlist 已做，池化未做）；R-19（工作区半成品） |
| **只有机制 / 缺证据** | CI 三条工作流、release 链（未在 GitHub 实跑）；E2E 门禁（`ci-heavy.yml` 模拟器矩阵，本地未累积"连续 20 次无超时"证据） |
| **明确不做** | iOS、批量接管、自建服务端/遥测上报、常驻前台服务、绕过鉴权 |

## 5. 技术债与真实性风险

- **插件能力边界**：frame/origin 校验依赖 flutter_inappwebview 6.2 beta 或本地最小补丁——引入 beta 属供应链决策，需 ADR。
- **上游协议为私有实测**：`RELAY-PROTOCOL-VERIFIED.md` 是抓包实证而非公开契约，官方页改版会让观察面失效；已有 `sseIgnored` 等诊断计数用于发现变化，自动告警已于 2026-09-18 落地（W-005：诊断页"观察面告警"分节与诊断包 `[alerts]` 段，仅 `OB2xx` 枚举码）。
- **生成文件陷阱**：`GeneratedPluginRegistrant.java` 未跟踪且被 test/build 交替重写；已成文，未自动化防护。
- **证据分散**：基线、探针、审计日志散落 `D:/tmp/zr/…`，仅台账引用；本轮起统一登记到 `docs/EVIDENCE.md`。

## 6. 外部阻塞清单

| 阻塞 | 类型 | 解除条件 |
| --- | --- | --- |
| 签名密钥处置 | 用户决策 | 对 ADR-003 拍板 |
| GitHub 账号 | 外部 | 恢复后推送 `7ce0485+`、实跑 CI 与发布链、定 tag 策略 |
| 真机矩阵 / soak / TalkBack / 生物识别 | 用户设备 | 按 `docs/RELEASE-CHECKLIST.md` 执行并归档 |
| 每设备 WebView 隔离、无凭据机型出口 | 产品决策 | 对 ADR-004 / ADR-005 拍板 |
