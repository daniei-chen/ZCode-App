# 威胁模型（v1.0.9 起）

> 本文是零基审计资产：每个"为什么可信"都能指向代码、测试或实测记录。
> 与 [ARCHITECTURE.md](ARCHITECTURE.md)、[SECURITY.md](../SECURITY.md)、
> [PRIVACY.md](PRIVACY.md)、[BENCHMARKS-RESULTS-v1.0.8.md](BENCHMARKS-RESULTS-v1.0.8.md) 配套。

## 一、资产

| 资产 | 位置 | 敏感度 |
| -- | -- | -- |
| `sid` / `hash` / `remoteControlToken`（控制链接凭证） | 仅 secure storage；链接本身在内存/剪贴板瞬时存在 | 等同密码 |
| 设备列表（名称、链接、时间） | secure storage（`DeviceStore`） | 高 |
| 会话标题与任务摘要 | 仅存在于内存与系统通知（受生物识别/遮罩控制） | 中高 |
| Release 签名私钥（keystore） | 本地 `android/` + GitHub Secrets；不入库 | 极高 |
| 更新通道（GitHub Release 资产） | GitHub 仓库 | 高 |
| APK 产物 | GitHub Release + 用户设备 | 高 |

## 二、威胁 → 防御 → 证据

| # | 威胁 | 防御 | 证据（代码/测试/实测） | 剩余风险 |
| -- | -- | -- | -- | -- |
| T1 | 恶意二维码/链接导入（伪造 host、私网地址） | 导入只接受 https + 精确 host `zcode.z.ai` + `/remote/v<数字>` 路径；拒绝 userInfo/非 443 端口/点段与空段 | `link_builder.dart` `isTrustedRemotePage`；`link_builder_trust_test.dart`（11 条） | 官方域被攻陷（供应链级，超范围） |
| T2 | 页面被替换后调用原生 bridge | 三层信任（origin/remote page/导航）+ 五个 bridge 回调 Dart 侧 `_bridgeAllowed()` 二次校验 + UserScript `allowedOriginRules` | `official_remote_page.dart`；`security_invariants_test.dart` | 官方页面自身 XSS（依赖上游修复） |
| T3 | 导航逃逸到非远控页面 | 主框架导航只放行 `/remote/v<数字>`；其余 CANCEL 并记 release 可见日志（只记 path） | `shouldOverrideUrlLoading`；实测零误拦（模拟器） | 新官方路由需随日志补充策略 |
| T4 | 更新包被替换（镜像/中间人） | 下载 URL 钉死 `github.com/2421873411a-rgb/zcode-app/releases/download/`；必须携带 SHA256 digest 才自动下载；回退路径经 `.sha256` sidecar 摘要校验；下载后全量 SHA256 比对 | `update_service.dart`；`update_service_test.dart`（含回退/404/文件名不符）；API 黑洞实测 | GitHub 账号被盗（见 T5） |
| T5 | GitHub 账号/Release 被劫持 | APK 需与已装应用同签名（预校验 `signerMismatch` + 系统安装器兜底）；Actions 产物 attestation；main 规则保护（Require PR + checks） | `MainActivity.inspectApk`、`precheckApk`、release.yml attestation | 账号与 keystore 同时失守（不可恢复级） |
| T6 | 旧版本降级攻击 | versionCode 单调递增；客户端预校验拒绝 downgrade（-25 场景有人话拦截） | `precheckApk`；`apk_precheck_test.dart` | 攻击者诱导卸载重装（需用户配合） |
| T7 | 日志泄露凭证/会话内容 | AppLog 规则：只记 path 不记 query；release 只保留白名单事件（nav blocked/silent reload/renderer）；页面 console 仅 debug 转发 | `app_log.dart`；`official_remote_page.dart`；security invariants | 用户主动导出的日志需自行甄别 |
| T8 | 本机其他应用读取凭证 | 凭证只在 `flutter_secure_storage`（Keystore 加持密）；`allowBackup=false`；FileProvider 仅暴露 `cache/updates` | `device_store.dart`；`AndroidManifest.xml`；security invariants；`device_store_chaos_test.dart` | root/取证级攻击（超范围） |
| T9 | 聊天/任务快照出现在最近任务 | 生物识别开启时切换后台以 FLAG_SECURE 遮蔽快照，回前台恢复 | `MainActivity.onPause/onResume` + `setRecentsCover` | 未开启生物识别的用户见 PRIVACY 说明 |
| T10 | 恶意 iframe/子 frame 注入 | 子 frame 导航同样限官方 origin；bridge 回调校验主文档 URL | `shouldOverrideUrlLoading`；`_bridgeAllowed` | 同源 iframe 共享页面权限（上游页面结构决定） |
| T11 | 解析炸弹（超大/畸形载荷） | JS 侧：4MB 上限、分片上限 64/count、TTL 60s、队列上限；Dart 侧：BridgeSchema 尺寸门禁、混沌/模糊测试 | `event_observer.dart`；`bridge_schema.dart`；chaos/fuzz 测试；遥测计数（异常全 0 实测） | 新协议形态需按遥测补充 |
| T12 | 通知被冒用/内容外泄 | 通知 ID 确定性；通道带版本后缀；锁屏可见性与生物识别绑定；通知内容受开关控制 | `notifier.dart`；`notifications` 相关设置 | 系统级通知读取（超范围） |

## 三、有意识的取舍（明确记录，不是遗漏）

1. **远程页路径采用 `/remote/v\d+` 而非固定 `{4}`**：为官方 v5+ 留版本递进空间，
   代价是理论上 `/remote/v999` 也会被信任。缓解：仍要求精确 host + https +
   无 userInfo；若官方确认固定版本，可在下一版收紧（改动点集中在
   `link_builder.dart` 一个正则，已被信任矩阵测试覆盖）。
2. **自定义 origin 解析保留在测试通道**（`allowCustomOrigin`，生产入口不可达）：
   供底层协议测试使用；生产信任链不经过该分支。
3. **WS 白名单只做到 host + `/ws` 路径级**：路径级收敛依据实测协议记录
   （`wss://zcode.z.ai/ws?mid=…`）+ 遥测计数；若官方出现新端点，`wsIgnored`
   计数会上升并可从诊断页发现，再按数据放宽。SSE 则**完全不观察**（实测捕获的
   全部事件通道为 WS/REST，EventSource 从未出现；`sseIgnored` 计数保留以便
   未来变化可被诊断页发现）。
4. **不引入 FCM/服务端推送**：通知依赖 WebView 存活，README 已如实描述，
   不承诺进程被杀后仍可达。

## 四、信任链全景（一句话版）

```
GitHub 源码（PR + required checks）
  → Actions 构建（正式 keystore，SHA256，ABI gate，attestation 自验证）
  → Release 资产（确定性命名 ZCode-v<版本>.apk + .sha256 + SBOM + manifest）
  → 应用内更新（digest 必需 + sidecar 回退 + 下载校验）
  → 安装前预校验（包名 / versionCode / 签名指纹）
  → 系统安装器（最终身份校验）
```
