# ZCode App 架构（v1.0.6 起 · 纯 WebView）

> 本文描述当前真实实现。v1.0.6 起应用只保留"原生外壳 + 内置 WebView"一条数据链路，
> 此前的原生 relay / 原生面板架构已整体移除；被清理的历史文档可从 git 历史找回。

## 总体形态

Flutter 单 Activity（`FlutterFragmentActivity`）应用，无底部 Tab、无原生会话面板：

- **无设备**：整个屏幕是 `ManagePage`（设备中心）——扫码/粘贴导入、排序、改名、删除、
  检查更新入口、设置。
- **有设备**：`Stack` 三层
  1. `IndexedStack`：每台设备一个 `OfficialRemotePage`（内置 WebView，加载 ZCode
     桌面端移动远程控制页）。设备常驻挂载，切换不重建、不重连。
  2. `ManagePage` 作为 launcher 覆盖层（`_launcherVisible`）：系统返回键先从 WebView
     摘要回到设备中心，再返回才退出应用。
  3. `_FloatingNoticeCard`：前台事件悬浮通知（5 秒自动消失，点击跳转到对应设备/会话）。

`activeTabProvider` 的语义是"当前前台的设备索引"，不再是 Tab 索引。

## WebView 信任边界

- 导航白名单只在 `useShouldOverrideUrlLoading: true` 时生效（插件默认 false，回调
  永远不会触发——这是踩过的坑）。
- 三个注入 UserScript 均带 `allowedOriginRules: {'https://zcode.z.ai'}`。
- `link_builder.dart` 负责控制链接解析：host 校验、拒绝环回/私网/保留地址、URL 重建。
- `sid`/`hash` 等凭证只进 secure storage；日志、测试、文档不得出现真实凭证。

## 更新链（Android 专属）

`app_shell` 启动时后台检查，仅确认有新版时弹一次应用内更新弹窗：

1. **检查**：`api.github.com releases/latest`（匿名限额 60 次/h/IP）→ 失败回退
   `github.com/releases/latest` 302 页面解析；回退路径**不伪造资产 URL**
   （`canDownload=false` + GitHub 入口兜底）。
2. **下载**：确定性资产名 `ZCode-v<version>.apk`；Range 断点续传（206 校验
   Content-Range 起点、416 严格判定已完成）；200MB 上限；SHA256 摘要校验；
   最多 4 次尝试。
3. **安装**：交给系统安装器（FileProvider + `ACTION_VIEW`）。安装前先做**预校验**
   （包名 + versionCode），把"无法降级安装(-25)"之类系统错误提前翻译成人话。
4. `markPrompted` 在弹窗真实展示之后落盘，避免生命周期竞争吞掉提示（U07）。

## 通知

- 事件源：`DeviceFeed`（审批请求 / 完成 / 失败）。
- 前台：悬浮卡 + 应用内提示音；后台/锁屏：系统通知（标题=会话标题，正文=任务摘要，
  点击直达对应设备/会话）。
- 通知 ID：`SHA256(deviceId\0type\0taskId)` 前 31 bit（Dart `hashCode` 跨进程不稳定，
  已弃用）。
- 提醒方式三选：系统音 / 静音 / 强提醒；通知通道 id 带版本后缀，升级时重建通道，
  避免旧的声音配置残留。

## 存储

- `flutter_secure_storage`：设备凭证、warmup 录制存档。索引损坏时用 `readAll()`
  前缀扫描自愈重建。
- `SharedPreferences`：主题、通知偏好、启动目标、最近设备。
- `MainActivity.onCreate` 清理 v1.0.0 遗留的常驻通知与通道（升级垫片）。

## Android 原生面

`MainActivity` 注册 5 个 MethodChannel：

| 通道 | 用途 |
|---|---|
| `zremote/keepalive` | 电池优化白名单（isBatteryIgnored / requestBatteryIgnore / MIUI 豁免） |
| `zremote/app` | 应用设置、系统通知开关状态 |
| `zremote/theme` | 夜间模式同步 |
| `zremote/notification_sound` | 默认通知音预览 |
| `zremote/update` | APK 预校验（inspectApk）与安装 |

## 平台门控

- 本项目仅支持 Android，不支持 iOS（仓库不含 ios/ 目录，不发布 IPA）。
- CI：`ci.yml` 跑 analyze/test、Android 构建与模拟器冒烟；`release.yml` 推 tag
  自动出 arm64 签名 APK + SHA256（密钥走 GitHub Secrets，tag 版本与 ABI 自动校验）。

## 目录

```text
lib/
  models/       设备、通知偏好数据模型
  services/     设备存储、WebView、通知、更新、电池优化
  state/        设备池、会话栈、事件流、页面状态
  ui/           设备中心、WebView 会话、更新弹窗、设置
android/        MainActivity、通知、升级清理垫片
```
