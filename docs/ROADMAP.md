# ROADMAP

当前版本线：以 GitHub Releases 与 `pubspec.yaml` 为准（本文只记录范围与计划，不复述具体版本号）。
支持范围与限制见 [SUPPORT.md](SUPPORT.md)。

## v1.1.x — 外部审计驱动的加固

> 计划代号 v1.1.0（见 [releases/v1.1.0.md](releases/v1.1.0.md) 的计划内容清单）；
> 实际发布版本为 **v1.1.2**（Pre-release，见 [releases/v1.1.2.md](releases/v1.1.2.md)，含出站 URL 策略与发布链自身修复）。
> 版本号与 tag 的对应关系只在 GitHub Releases 与 `pubspec.yaml` 记录，本文不复述。

四份外部深度审计（F01–F26、100 项验收矩阵）合并后的统一升级，逐项落地并附证据：

### 发布链与供应链

- [x] 来源门禁：只有受保护 main 上的提交能出签名包；tag 必须等于 `pubspec.yaml`；
      versionCode 递增；签名证书与上一稳定版一致（密钥轮换走显式流程）
- [x] 四重 digest 一致 + attestation 自验证 + 资产重下载复核 + 幂等拒绝覆盖
- [x] 三层 SBOM（Dart 依赖图 + Gradle release 运行时含 POM 许可 + APK 原生库
      逐个 SHA-256），APK 摘要写进 SBOM 根组件；schema 与覆盖校验
- [x] 依赖漏洞门禁（OSV）：发布 fail-closed、例外须带原因与到期日
- [x] 发行说明与 tag 一致性门禁；文档防漂移检查（SDK 下界/支持范围/版本复述/行尾）

### 设备与状态

- [x] 生命周期按 deviceId（删除/换链接/选择漂移）；DeviceStore 串行化与损坏自愈
- [x] 首载失败出口、静默重载预算、renderer 回收重建、连接状态只由 relay 证据判定

### 通知与交互

- [x] 跨消息幂等（限定窗口 + resolved 清理）；待处理交互按任务维护
- [x] 跳转确认（attemptId/结果/失败原因）与页内返回回执（多策略 + 点击后自证）

### 观测、安全与无障碍

- [x] 结构化日志（事件码 + 白名单字段 + 统一脱敏）、按设备遥测、脱敏诊断包
- [x] 生物识别门禁开关（开启/关闭都需验证）、凭证指纹去重、扫码失败可恢复
- [x] 字体 100/130/200% × 四档尺寸的布局矩阵与弹窗滚动契约、图标按钮可朗读标签

### 仍待完成的验收（不在本版承诺内）

- [ ] 真机矩阵（D1–D4 + 厂商 ROM）、1/2/3/5 设备并发、网络与后台矩阵、48h soak
- [ ] 真实候选包按支持矩阵截图、真机 TalkBack 实测
- [ ] 连续 20 次模拟器 E2E 无基础设施超时（每夜运行累积证据）

## v1.0.8 — WebView Hardening & Architecture Cleanup（已发布 ✅）

- [x] 发布走完整 workflow：tag → 签名构建 → arm64 ABI 校验 → SHA256 → attestation → Release（versionCode 9，28.1MB）

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

## v1.0.9（已发布 ✅）

- [x] WS/SSE 白名单（W2）：只观察官方 relay（host + /ws 路径），其余透明计数
- [x] Renderer 崩溃恢复（v1.2.0 D）：onRenderProcessGone → generation 重建
- [x] SBOM（CycloneDX）+ release-manifest.json + attestation 自验证（v1.4.0 A/B/C）
- [x] emulator API 矩阵 [30, 34]（v1.2.0 C）
- [x] THREAT-MODEL / SECURITY / PRIVACY / OPERATIONS-RUNBOOK（密钥灾备 + 回滚制度）
- [x] Bridge/解析器模糊测试电池（v1.3.0 D）
- [ ] 真机矩阵与 soak 数据录入（BENCHMARKS-RESULTS，需真机）
- [ ] 诊断包导出（zip：日志 + 状态快照，下一版候选）

历史规划与原生时代迭代记录已清理，可从 git 历史找回。

历史规划与原生时代迭代记录已清理，可从 git 历史找回。
