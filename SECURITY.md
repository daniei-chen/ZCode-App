# 安全策略

## 报告漏洞

- 首选：通过 GitHub 的 [私有漏洞报告](https://github.com/2421873411a-rgb/ZCode-App/security/advisories/new)（Private vulnerability reporting，已开启）。
- 也可以在仓库 Issues 提交，但**不要在公开 Issue 中粘贴任何凭证**（`sid`、`hash`、`remoteControlToken`、控制链接）。

## 支持范围

- 仅支持**最新 Release 版本**（当前为 v1.0.8 线）。
- 更早版本请先升级复现；旧版本不单独修复。
- 项目仅支持 Android，不提供 iOS 支持。

## 响应方式

- 个人项目、best-effort 响应：确认后按严重程度排期，修复随下一版本发布（发布链见
  [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md)）。
- 修复版本会按"更高 versionCode 的补丁版本"发布，Android 无法回滚旧包——
  回滚制度见 [docs/OPERATIONS-RUNBOOK.md](docs/OPERATIONS-RUNBOOK.md)。

## 凭证卫生（对使用者）

- 控制链接等同密码：不要发到 Issue、讨论区、截图或任何公开位置。
- 链接只应通过扫码/粘贴进入应用；应用内凭证只存于系统加密存储。
- 怀疑泄露时：在桌面端重新生成二维码/链接即可让旧链接失效。

## 安全设计速查

- 威胁模型与防御证据：[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md)
- 数据流与日志边界：[docs/PRIVACY.md](docs/PRIVACY.md)
- 架构（信任三层模型）：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
