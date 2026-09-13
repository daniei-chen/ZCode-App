# 支持范围与限制

> 本文是**承诺边界**：用户与维护者都据此判断"哪些环境算我们支持、哪些不算"。
> 版本号只有一处权威来源——`pubspec.yaml` 与 GitHub Release；文档里不再复述
> 具体版本号，避免"文档写 vX、包是 vY"的漂移（由 `scripts/check-doc-drift.py` 守住）。

## 一、平台支持

| 项 | 实际范围 | 依据 |
| -- | -- | -- |
| 操作系统 | Android 7.0（API 24）及以上 | `android/app/build.gradle.kts` 的 `minSdk = 24` |
| 目标/编译 SDK | 跟随 Flutter 稳定版（`flutter.targetSdkVersion` / `compileSdkVersion`） | 同上 |
| CPU 架构 | **仅 arm64-v8a**（正式包单 ABI） | 发布工作流强制校验 APK 内 `lib/` 只有 `arm64-v8a` |
| 桌面端 | ZCode 桌面端提供的"移动端远程控制"功能 | 见 [COMPLIANCE.md](COMPLIANCE.md) |
| iOS | **不支持**（Android 专用） | 仓库无 iOS 目标 |
| 平板 / 横屏 / 分屏 | 支持；布局按最短边 ≥600dp 视为平板 | `test/responsive_layout_test.dart` |

### CI 实测覆盖 vs 承诺支持

承诺支持 API 24+，但 CI 只在 **API 30 与 API 34** 的模拟器上跑 E2E
（`ci-heavy.yml` 的 `android-emulator`）。落在两者之间的版本属于"按 minSdk
承诺、未逐版本实测"；如果某个系统版本出现专属问题，按 Issue 优先级处理。

## 二、依赖与工具链

| 项 | 范围 | 依据 |
| -- | -- | -- |
| Dart SDK | 与 `pubspec.lock` 的 `sdks.dart` 下界一致（CI 校验两者相等） | `scripts/check-doc-drift.py` |
| Flutter | 3.47.3（stable；与 CI 固定版本一致） | `.github/workflows/*.yml` |
| JDK（构建） | 17（Temurin） | 同上 |
| Android Gradle Plugin | 见 `android/settings.gradle.kts`（SBOM 里记录实际版本） | `ZCode-v*.sbom.cyclonedx.json` |

## 三、功能限制（明确不承诺的）

- **不做多目标批量接管**：一台手机管理多台自有设备，但不做批量脚本化操作。
- **不绕过官方鉴权**：relay 的单配对限制（`sessionConflict` / `kicked`）是设计，不去规避。
- **无自建服务端**：不上传遥测、不做崩溃上报；数据只在手机与自有电脑之间往返。
- **WebView 渲染的官方页面**是远控界面的唯一来源；原生层只做启动器、通知、
  更新与观测，不复制官方 UI。
- **通知依赖系统通知权限与后台策略**：厂商 ROM 的激进省电策略可能导致延迟，
  诊断页提供电池优化入口与状态说明。

## 四、质量门禁（可复核）

| 门禁 | 位置 | 说明 |
| -- | -- | -- |
| analyze + test | `ci.yml` / `check` | 每次 push/PR |
| 注入脚本行为断言 | `scripts/check_injected_js.mjs` | 观测钩子与跳转脚本的 JS 语法与边界行为 |
| 发布资产校验 | `scripts/verify-release-artifacts.py` | manifest schema、四重 digest、SBOM 覆盖与 APK 绑定、attestation |
| 依赖漏洞门禁 | `scripts/check-dependency-advisories.py` | OSV；发布 fail-closed |
| 布局与无障碍矩阵 | `test/responsive_layout_test.dart` | 4 尺寸 × 3 字体缩放 |

真机矩阵（供应商 ROM、1/2/3/5 设备并发、网络与后台矩阵、48h soak）由维护者在
发布前手工执行并归档；文档只承诺上面这些**可自动复核**的部分。
