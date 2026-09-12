# ROADMAP

当前版本线：v1.0.6（纯 WebView 架构定格，Android-only，不支持 iOS）。

## v1.0.7 — Release & Security Closure（进行中）

发布链与更新器收口，不是功能版。

- [x] GitHub Secrets（KEYSTORE_BASE64 / KEYSTORE_PASSWORD）配置完成
- [x] release.yml：tag↔pubspec 校验、确定性资产名 ZCode-v<version>.apk、SHA256 资产、发布说明文件
- [x] release.yml：钉死 arm64 单包并自动验证产物 ABI（R2）
- [x] 打包层钉死 ABI：packaging.jniLibs.excludes 剔除非 arm64 库（`--target-platform` 只过滤 Flutter 自家库、插件 AAR 不受限；v1.0.6 起资产实为 fat APK，此前被体积误判为 arm64 单包）
- [x] WebView 黑屏守卫：首载超时或空白帧自动静默刷新一次（用户上报，只自动重试一次）
- [x] 应用内更新 fail-closed：资产必须带合法 SHA256 digest 才自动下载（U1）
- [x] 资产选择只认 ZCode-v<version>.apk 精确名，删除 ZCode.apk / 任意 .apk 回退（U2）
- [x] 安装前预校验：包名 + versionCode，"无法降级安装(-25)"在人话界面拦截
- [x] 移除 iOS：ios/ 目录、IPA 发布、iOS CI 巡检全部删除（I1/I2 随之消失）
- [x] DeviceStore 自愈重写：排除索引键自身、只信任解析成功且键值 id 一致的设备（D1）
- [x] inspectApk 增加签名证书校验（signingInfo 对比已装应用，U3）
- [x] canRequestPackageInstalls 未授权时引导系统设置的安装 UX（U4）
- [x] Android 最近任务隐私遮罩，与生物识别 10 秒重锁解耦（P1）
- [x] 更新下载可取消（U5）
- [x] security_invariants_test：导航白名单 flag、kDebugMode console、FileProvider scope 等硬不变量（T2）
- [x] 模拟器 E2E 扩充：通知初始化、MethodChannel、APK inspect、生命周期（T1）
- [x] v1.0.7 发布走完整 workflow，全程无手工上传文件（R1 验收 ✅ tag→签名→ABI 校验→SHA256→Release 全自动）

## v1.0.8 — WebView Hardening（候选）
- [x] 页面回退路径经 .sha256 sidecar 恢复自动下载：修复 API 被限流（VPN 共享出口常见）时"发现新版本但没有可下载 APK"的体验不一致，fail-closed 语义不变

- KeepAlive 死代码移除，电池优化能力独立命名（BatteryOptimizationService，K1）
- 电池优化文案改为"改善后台存活概率"，不承诺通知必达（K2）
- WebView 信任从域名级收紧到页面级（trusted remote routes + 端口校验，W1）
- EventObserver 收敛为已知 endpoint/topic 白名单（W2）
- thirdPartyCookiesEnabled 必要性验证（W3）
- 多设备（1/2/3/5 台）内存与功耗压测
- AppLog 统一日志

## v1.1.0 — 体验增强（远期）

诊断中心（通知 / WebView / 更新 / 连接状态与后台存活建议），不再重做原生 UI。

历史规划与原生时代迭代记录已清理，可从 git 历史找回。
