# 安全策略

## 报告漏洞

- 首选：通过 GitHub 的 [私有漏洞报告](https://github.com/daniei-chen/ZCode-App/security/advisories/new)（Private vulnerability reporting，已开启）。
- 也可以在仓库 Issues 提交，但**不要在公开 Issue 中粘贴任何凭证**（`sid`、`hash`、`remoteControlToken`、控制链接）。

## 支持范围

- 仅支持**最新 Release 版本**（版本号以 GitHub Releases 页与 `pubspec.yaml` 为准，本文不复述）。
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

## 供应链（v1.1.0 起）

发布产物的依赖清单与漏洞门禁都是可复核的，规则如下：

- **SBOM**：每个 Release 附带 `ZCode-v<version>.sbom.cyclonedx.json`，合并三层清单——
  Dart 依赖（`pubspec.lock` + pub 缓存里的包内声明，构成依赖图）、Android release
  运行时依赖（Gradle 解析结果，含 Maven PURL 与来自 POM 的许可）、APK 里的原生库
  （`lib/<abi>/*.so`，逐个记录 SHA-256）。同时写入构建工具链版本（Python/PyYAML/
  Gradle/JDK/Flutter/Dart/AGP），并在根组件记录这次 APK 的 SHA-256。
  SBOM 由 `scripts/generate-sbom.py` 生成，`scripts/verify-release-artifacts.py --sbom`
  校验（schema、三层非空、bom-ref 唯一、依赖引用可解析、许可齐备、原生库带哈希、
  SBOM 记录与 APK 摘要一致）。
- **许可**：Maven 许可取自 POM 的 `<licenses>`，Dart 许可取自 pub 缓存里的 LICENSE
  文件（只做保守的 SPDX 识别）。识别不出时写 `NOASSERTION` 而不是猜——SBOM 里的
  `zcode.license.noassertion` 计数与 `zcode.license.source` 属性说明了每个结论的来源。
- **漏洞门禁**：`scripts/check-dependency-advisories.py` 用 [OSV](https://osv.dev)
  查询 SBOM 里所有随包发布的组件（`scope != excluded`）。
  - 发布侧：`--fail-on high`，**fail-closed**——有未豁免的 high/critical，或 OSV 不可达，
    都拒绝发布（重跑工作流即可）。
  - PR 侧：`--fail-on critical --soft-fail-if-unreachable`，只报告不阻断，避免上游抖动卡住日常合并。
  - 例外只能登记在 [`scripts/security-exceptions.json`](scripts/security-exceptions.json)，
    每条必须带 `reason` 与 `expires`（UTC 日期）；**过期的例外本身会让门禁失败**，
    防止"临时豁免"永久留存。
- **依赖评审**：GitHub 的 dependency-review 动作保留为非阻断检查（仓库 Dependency
  Graph 数据未就绪前它无法给出结论），真正的阻断由上面的 OSV 门禁承担。
- **构建来源**：正式 APK 由 tag 触发的发布工作流构建，附 GitHub 构建来源证明
  （`gh attestation verify`），并强制 versionCode 递增与签名证书连续性
  （见 [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md)）。

## 安全设计速查

- 威胁模型与防御证据：[docs/THREAT-MODEL.md](docs/THREAT-MODEL.md)
- 数据流与日志边界：[docs/PRIVACY.md](docs/PRIVACY.md)
- 架构（信任三层模型）：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
