# 发布与交付检查清单

## 本地或 CI 发布前

- 使用 Flutter 3.47+、Dart 3.10+、JDK 17。
- 执行 `flutter pub get`、`flutter analyze`、`flutter test`。
- 执行 `flutter build apk --release --target-platform=android-arm64`；没有正式 `android/key.properties` 和对应 keystore 时，构建必须失败。
- 在真机上验证：生物识别门禁、后台回前台、WebView 导航白名单、通知权限和应用内更新全链路。

## 源码包

从项目根目录执行：

```powershell
pwsh -File scripts/package-source.ps1
```

脚本只复制源码交付白名单，并拒绝以下内容：

- `.git/`
- `tools/` 和抓包 evidence
- `key.properties`、`local.properties`
- `.dart_tool/`、`build/`、`coverage/`

输出为 `dist/zcode-control-source.zip`。交付前应查看归档条目，确认没有本机路径、会话凭证、真实链接或抓包文件。

## 发布凭证

- Android release keystore 只通过 CI secret 恢复（`KEYSTORE_BASE64` / `KEYSTORE_PASSWORD`；生产审批由 `production` environment 承载，密钥材料只出现在 `build-sign` 作业并在构建后立即删除）；不允许 debug key fallback。
- 新包的 versionCode 必须大于 GitHub 上最新已发布资产的 versionCode，否则用户会碰到"无法降级安装(-25)"；发布前用 `aapt dump badging` 核对，不要用 `--split-per-abi` 产物对外分发（其 versionCode 带 ABI×1000 偏移）。
- 二维码中的 `sid`、`hash`、`remoteControlToken` 等同于密码，不进入日志、截图、issue 或交付包。
- 发布包的 Android bundle identifier 为 `com.zcode.app`。
- 发布后同步仓库门面：About 描述里的"当前版本"（`gh repo edit --description`）、README/README.en 的版本与测试数。

## 发布信任链（v1.1.0 起）

发布流程是三个作业，顺序不可调换：

1. **verify**（来源门禁，恢复任何密钥之前）：tag 版本必须等于 `pubspec.yaml`；发布提交必须已合入受保护 `main`，默认还必须是 `main` 的 HEAD（有意重跑才允许 `allow_ancestor=true`）。`v*` tag 受规则集保护：不可删除、不可移动，仅维护者账号可创建。
2. **build-sign**（唯一接触 keystore 的作业，承载 `production` 环境审批）：先核对上一稳定版 manifest 可读、`versionCode` 必须递增，再恢复 keystore 构建；APK 签名证书必须与上一稳定版一致；构建完成后立即从工作区删除密钥材料。
3. **publish**（从不接触签名材料）：校验 manifest schema 与 digest 四重一致（重算 APK SHA256 = sidecar = manifest = attestation 主题）→ 生成并自验证来源证明 → 发布为 **Pre-release** → 重新下载已发布资产再验一次摘要。

演练与负例（不签发任何东西）：

```bash
gh workflow run release.yml --ref main -f dry_run=true             # 正向：main HEAD 通过来源门禁
gh workflow run release.yml --ref <feature-branch> -f dry_run=true # 负向：未合入 main 的提交被拒绝
```

**Pre-release → 正式**：默认发 Pre-release（应用内更新器只认 `/releases/latest`，不会向用户推送）。真机矩阵与 48h soak 完成后执行：

```bash
gh release edit v1.1.0 --prerelease=false --latest
```

## CI 结果记录

不要手工填写测试数量。把 CI 的 `flutter analyze` 和 `flutter test` 原始结果作为发布证据；若本地没有 Flutter SDK，应明确标记为“未在本地执行”。

## 发布后观察期（soak）

- 发布后观察 24–48 小时：更新成功率（应用内提示 → 下载 → 安装完成）、
  崩溃反馈、通知是否漏发、后台存活报告。
- 观察期内出现的 P1 回归走修复分支 + PR（main 已启用规则保护），
  修复后按同一发布流程出补丁版本，不做热修直推。
- 观察期结束后更新 README/About 描述中的版本口径为最新已发布版本。
## CI 自动出包启用清单（W-031，iter13 记录）

`release.yml` 已具备完整签名发布链（keystore 恢复 → arm64 构建 → 签名连续性校验 → SBOM → 发布资产），
在仓库设置完成以下配置前，tag 触发的运行会在 `Verify provenance` 一步拒绝（保护性失败，不影响手工发布）。

### 1. 配置仓库 Secrets（Settings → Secrets and variables → Actions）

| Secret | 内容 | 生成方式（在你本机做，AI 不接触密钥） |
| --- | --- | --- |
| `KEYSTORE_BASE64` | 发布 keystore 的 base64 | `certutil -encode android/app/zcode-app-release.jks tmp.b64 && `（去掉首尾行）或 git-bash：`base64 -w0 android/app/zcode-app-release.jks` |
| `KEYSTORE_PASSWORD` | keystore 的 store/key 口令（脚本约定两者相同） | 你保存的口令 |

密钥别名固定为 `zcode-app`（脚本内写死），无需额外 Secret。

### 2. 分支保护与发版路径

- 保护 `main`：Settings → Branches → Add branch protection rule（至少禁止直推、要求 PR）。
- 发版路径：`release/v1.0.0` → PR 合并进 `main` → 在 `main` HEAD 上打 tag（`vX.Y.Z`，版本号必须与 `pubspec.yaml` 一致）。
- 首次接通建议先跑演练：Actions → release → Run workflow（`dry_run: true`），确认签名与校验链全绿后再打正式 tag。

### 3. 当前已知差异（截至 2026-09-19）

- `main` 停在 95d6b2a，`release/v1.0.0` 领先大量提交；CI 出包前需先合并同步。
- 合并后把 v1.0.0 tag 重指到 main HEAD（或按新版本号打新 tag，见 DEC-18）。
