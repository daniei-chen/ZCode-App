# ROADMAP

当前版本线：v1.0.8（纯 WebView，Android-only；三版内容一次性收口）。

## v1.0.8 — WebView Hardening & Architecture Cleanup（已交付，待真机 smoke 后发布）

### W1 页面级信任

- [x] `isTrustedOrigin` / `isTrustedRemotePage` 三层拆分；主框架导航只放行
  `/remote/v<数字>`；显式非 443 端口拒绝；bridge 回调 `_bridgeAllowed()`
  二次校验；信任矩阵测试 11 条 + 安全不变量 4 条

### W3 Cookie 最小化

- [x] `thirdPartyCookiesEnabled: false`（真机全流程 smoke 通过后保持；
  失败则记录依赖流程与证据再评估）

### K1/K2 KeepAlive 清理

- [x] Kotlin 服务类与 Dart 服务文件删除；通道更名 `zremote/battery`；
  文案改为"改善后台运行稳定性"，不承诺通知必达

### Reliability（原 v1.0.9）

- [x] EventObserver telemetry：`zrStats` 计数（fetch 命中/跳过、WS/SSE、
  分片异常、队列丢弃），诊断页可见，只含数字不含 URL/内容
- [x] fetch 白名单：只 clone 事件相关命名空间，未命中计数供诊断核对
  （WS/SSE 是事件主通道，不受此表影响）
- [x] fragment TTL/边界：`fragmentIndex` 范围、`fragmentCount` 上限、
  60 秒过期清扫、异常计数
- [x] CI 分层：fast check 每次 push/PR 必跑；android 构建 + 模拟器 E2E 按
  路径过滤触发；新增 dependency-review（仅 PR）
- [x] 压测/网络/后台协议：`docs/BENCHMARKS.md`（真机数据待录入）

### Production Engineering（原 v1.1.0）

- [x] AppLog 统一日志：环形 500 条、Release 白名单规则、诊断页由用户主动导出
- [x] 诊断中心：版本 / 环境 / 设备 / 通知 / 后台 / 安全 / 更新 / 观测 / 日志
  只读页，绝不出现 sid/hash/token/会话内容
- [x] Dependabot（pub + github-actions，weekly；不自动合并 major）
- [x] APK Artifact Attestation（`gh attestation verify` 可验构建来源）
- [x] main Ruleset：Require PR + Required checks（check、android）
- [x] 发布后 soak 流程写入 `docs/RELEASE-CHECKLIST.md`

## 下一步（v1.0.9 候选）

- 真机 benchmark 数据录入（BENCHMARKS.md）
- 依遥测结果收紧 WebSocket URL allowlist
- flutter_inappwebview 版本评估（由 Dependabot PR 驱动）
- 诊断中心导出诊断包（zip：日志 + 状态快照）

历史规划与原生时代迭代记录已清理，可从 git 历史找回。
