# ROADMAP

当前版本线：v1.0.7（纯 WebView 架构定格，Android-only，发布链全自动）。

## v1.0.8 — WebView Hardening & Architecture Cleanup（三道合一，进行中）

- [x] W1 页面级信任：`isTrustedOrigin` / `isTrustedRemotePage` 三层拆分，主框架
  导航只放行 `/remote/v<数字>`，非 443 端口拒绝，bridge 回调 Dart 侧
  `_bridgeAllowed()` 二次校验；配套信任矩阵测试
- [x] W3 第三方 Cookie 最小化关闭（`thirdPartyCookiesEnabled: false`）；
  真机全流程 smoke 通过后永久保持，失败则记录依赖流程与证据再评估
- [x] K1 KeepAlive 彻底移除：`KeepAliveService.kt` 与 `services/keepalive.dart`
  删除，通道更名 `zremote/battery`，遗留清理改用字符串组件名
- [x] K2 文案改真实：设置页改为"改善后台运行稳定性"，不承诺通知必达
- [x] 安全不变量扩充：远程页判定、端口、bridge 守卫、Cookie、KeepAlive 文件缺失
- [ ] v1.0.8 真机 smoke（手机 + 平板：导入 / 重连 / 切换 / 发送 / 刷新 / 前后台）
  后发布

## v1.0.9 — Reliability（Observer + 压测）

- EventObserver 观测模式：debug-only telemetry（transport/host/path/命中率），
  绝不记录 query/cookie/body
- EventObserver 白名单化：fetch 只 clone 已知 interesting endpoint；
  WebSocket 收敛到 URL allowlist + 已知 envelope；未知端点完全不 clone
- Fragment assembler 加强：fragmentCount 上限、index 范围、TTL 与过期清理；
  bridge 计数器（dropped/oversized/invalid，debug 数字）
- 多设备压测：1/2/3/5 台 WebView 的冷启动、内存、切换、后台 30min、系统回收
- 网络可靠性：VPN / 移动网络 / 弱网 / 下载中断恢复 / 各错误态文案
- CI 分层提速：fast check（每次 push）；android build 与 emulator E2E 条件触发
  （路径过滤 / PR / tag / 手动）

## v1.1.0 — Production Engineering

- main 治理：Ruleset 增加 Require PR + Required checks（check、android；
  emulator 稳定后加入）
- 依赖治理：Dependabot（pub + github-actions，weekly）、major 人工审
- APK Artifact Attestation（GitHub build provenance），可选 SBOM
- AppLog 统一日志 + Release 白名单规则 + ring buffer
- 诊断中心：版本 / 设备 / 通知通道 / 后台 / 更新 / 安全状态只读页，
  绝不出现 sid/hash/token/会话内容

历史规划与原生时代迭代记录已清理，可从 git 历史找回。
