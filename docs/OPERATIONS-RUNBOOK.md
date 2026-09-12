# 运维手册（密钥灾备 · 回滚 · 紧急修复）

> 仅与维护者相关。任何真实密钥、密码、口令**不得**写入本文件或仓库任何位置。

## 一、Release 签名密钥灾备

### 现状与要求

- keystore：`android/zcode-app-release.jks`（本地，已 gitignore）；
  CI 通过 `KEYSTORE_BASE64` / `KEYSTORE_PASSWORD` 两个仓库 Secret 恢复。
- 签名身份一旦丢失，**已安装用户无法再收到任何更新**（系统拒绝不同签名的覆盖安装）。

### 必备备份（至少三份，互不依赖）

1. 本地加密备份（口令与 keystore 分开存放）。
2. 离线物理备份（U 盘/移动硬盘，加密压缩）。
3. 第二地点的离线副本（不同物理位置）。

备份内容 = keystore 文件 + `keyAlias` + `storePassword`/`keyPassword`；
**密码不要和 keystore 放在一起**。

### 恢复演练

- 每半年做一次"清空环境变量与本地文件后用备份重建一次 debug 级签名构建"，
  确认备份可用（不发布，只验证能解出 keystore 并通过 `apksigner verify`）。

### 泄露处置

| 场景 | 处置 |
| -- | -- |
| keystore 泄露 | **无法轮换**（轮换=失去全部存量设备的更新能力）。立即：停用相关 Secret、审查发布历史、在 Release/README 发布安全公告并给出迁移指引（卸载重装）。 |
| GitHub Secret 泄露 | 立即在 Settings → Secrets 轮换 `KEYSTORE_PASSWORD`（keystore 本体若未泄露仍保持同一把），并检查最近 Actions 运行记录。 |
| GitHub 账号被盗 | 冻结发布（删除 Actions 权限/停用 workflow）、轮换 Secret、审计 Releases；恢复后按紧急修复流程发补丁版本。 |
| 电脑被盗/损坏 | 用离线备份重建；`key.properties` 由备份的密码重写。 |

## 二、回滚制度

Android 不支持降级安装，**"回滚"= 发布更高 versionCode 的补丁版本**：

1. 从 known-good 源码（上一个良好 tag）切分支。
2. 应用最小修复（或直接 revert 问题提交）。
3. `pubspec` 版本号 +1（patch），versionCode 递增。
4. 走完整 Release 流程（PR → CI → tag → workflow 自动签名发布）。
5. Release 说明中写明"回滚自 x.y.z 的回归"与规避措施。

**禁止**：重新发布旧 APK、移动已发布的 tag、手工替换 Release 资产。

## 三、紧急修复流程（main 已启用规则保护）

1. 从 `main` 开 `hotfix/<问题>` 分支 → 修复 + 回归测试。
2. 开 PR；必需检查（check + android）必须全绿。
3. 合并 → bump 版本 → 写 `docs/releases/<tag>.md` → 推 tag → 工作流自动发布。
4. 发布后按 [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md) 进入 24–48h 观察期。

## 四、暂停发布

需要立即冻结发布时：停用 release workflow（Actions 页面）或删除临时 tag；
恢复前先确认密钥与账号状态。
