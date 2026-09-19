# 隐私与数据流

> 原则：应用没有自建服务端，不上传任何遥测；所有数据要么在设备本地，
> 要么往返于「你的手机 ↔ 你的电脑」之间（经官方 ZCode 远控链路）。

## 一、应用存了什么

| 数据 | 存储 | 说明 |
| -- | -- | -- |
| 设备列表（名称、链接、创建时间、顺序） | `flutter_secure_storage`（系统 Keystore 加持） | 含 `sid`/`hash` 等凭证；`allowBackup=false` 阻止云备份带出 |
| 设备索引 | 同上 | 损坏可自愈重建（混沌测试覆盖） |
| warmup 录制存档 | 同上 | 仅 GET/HEAD 面板请求；换链接即清除 |
| 主题 / 通知偏好 / 启动目标 / 最近设备 | SharedPreferences（明文） | 不含凭证 |
| 更新下载的 APK 与 `.part` | 应用缓存 `cache/updates/` | FileProvider 仅暴露该目录；安装后可清理 |
| 运行日志（AppLog 环形 500 条） | 仅内存 | 不落盘、不上传；诊断页由用户主动复制导出 |
| WebView 本地存储（Cookie / DOM storage / HTTP cache / IndexedDB） | Android WebView 数据目录 | 只属于官方远控页面；换凭证、移除设备、锁定擦除时清空（见下） |

### WebView 本地存储清单与清理策略（F19）

| 类型 | 存什么 | 何时清 |
| -- | -- | -- |
| cookies | 远控页的会话语义；不使用第三方 Cookie（`thirdPartyCookiesEnabled=false`） | 换凭证 / 移除设备 / 锁定擦除 |
| localStorage | `zcode-theme` 等页面偏好 | 换凭证 / 移除设备 / 锁定擦除 |
| sessionStorage | 页面会话级状态 | WebView generation 重建（渲染进程回收、换凭证）时随上下文消失 |
| HTTP cache | 静态资源缓存，不含业务凭证 | 换凭证 / 移除设备 / 锁定擦除 |
| IndexedDB | 官方页面自行使用 | 换凭证 / 移除设备 / 锁定擦除 |

清理动作在 [lib/services/webview_storage.dart](../lib/services/webview_storage.dart)（与上面的清单同处一处，
避免文档与实现漂移）；诊断页会展示同一份清单，用户可自查当前策略。

## 二、日志边界（硬规则）

- **永不记录**：`sid`/`hash`/`remoteControlToken`、完整 URI（只允许 path）、
  query、cookie、Authorization、WebSocket 正文、会话正文与任务内容。
- 日志由 [lib/services/structured_log.dart](../lib/services/structured_log.dart) 统一约束：
  每条日志必须带**事件码**（`WV101`/`JP302`/`UP600`…），字段只能来自白名单
  （route 只保留 `scheme://host/path`、设备只记前 8 位短 id、原因只允许机器标签、
  异常摘要先脱敏再压成单行并截断 120 字符）——**没有自由文本字段**，
  调用方写不进会话标题、正文或 payload。
- 写入环形缓冲前，整行再过一次统一脱敏（凭证参数、JWT/长不透明串、URL query
  一律替换为 `<redacted>`），这是防止调用点手拼字符串的第二道防线。
- Release 构建只保留白名单事件：导航被拦（scheme/host/path）、黑屏守卫静默
  重载（原因）、renderer 崩溃/无响应。其余调试日志仅 debug 构建输出，
  诊断页会显示"Release 下丢弃的调试日志条数"，避免误以为日志被删。
- 页面 `console` 仅在 debug 构建转发。

## 三、出站网络

| 目标 | 用途 | 携带数据 |
| -- | -- | -- |
| `github.com` / `api.github.com` | 检查更新、下载 APK | 无用户数据；匿名请求 |
| `zcode.z.ai`（WebView 内） | 官方远控页面与 relay `wss://zcode.z.ai/ws` | 控制链接凭证、会话请求（与桌面端官方链路一致） |
| 无其他 | — | 无广告、无统计、无崩溃上报 SDK |

## 四、通知与快照

- 通知内容默认受系统通知权限控制；开启生物识别后锁屏内容自动遮蔽。
- 开启生物识别时，切后台会以 FLAG_SECURE 遮蔽最近任务快照，回前台立即恢复；
  前台正常截图不受影响。
- 未开启生物识别的用户：最近任务可能显示应用当前画面（与系统内其他应用一致）。

## 五、诊断数据

- 诊断页（设置 → 诊断信息）只读展示版本/环境/设备数量/权限状态/观测计数/观察面告警/WebView
  存储清单；不显示链接、凭证、会话内容。
- 遥测计数（fetch/WS 命中与异常；SSE 现仅保留一个"已被忽略"的计数，不读其正文）
  **按设备分别保存**（键为设备短 id + generation），
  只含白名单计数键与有限非负整数；白名单之外的键、NaN/Infinity/超大值一律丢弃。
- 观察面告警（诊断页"观察面告警"分节与诊断包 `[alerts]` 段）**完全由上述计数派生**：
  输出只有 `OB2xx` 告警码与触发计数（例如"SSE 通道出现""白名单未命中率高"），
  不含任何 URL、host 或页面内容——它提示的是"官方页协议可能变了"，不是变成了什么。
- "复制日志"与"复制诊断包"都由用户主动触发，复制到系统剪贴板，应用自身不上传。
  诊断包内容固定为：版本、平台枚举、开关布尔值、设备**短 id**、状态枚举、观测计数、
  观察面告警码、存储清单与结构化日志——调用方接口上就没有传入链接/凭证/正文的口子，
  渲染时还会再过一次统一脱敏；`test/diagnostics_bundle_test.dart` 用 canary 串做零命中回归。
