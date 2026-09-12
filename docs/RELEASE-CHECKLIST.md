# 发布与交付检查清单

## 本地或 CI 发布前

- 使用 Flutter 3.47+、Dart 3.10+、JDK 17。
- 执行 `flutter pub get`、`flutter analyze`、`flutter test`。
- 执行 `flutter build apk --release`；没有正式 `android/key.properties` 和对应 keystore 时，构建必须失败。
- 在 macOS 上执行 `flutter build ios --release --no-codesign`，确认 iOS 检查不是允许失败的旁路任务。
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

- Android release keystore 只通过 CI secret 恢复（`KEYSTORE_BASE64` / `KEYSTORE_PASSWORD`，已在仓库配置）；不允许 debug key fallback。
- 新包的 versionCode 必须大于 GitHub 上最新已发布资产的 versionCode，否则用户会碰到"无法降级安装(-25)"；发布前用 `aapt dump badging` 核对，不要用 `--split-per-abi` 产物对外分发（其 versionCode 带 ABI×1000 偏移）。
- 二维码中的 `sid`、`hash`、`remoteControlToken` 等同于密码，不进入日志、截图、issue 或交付包。
- 发布包的 Android bundle identifier 为 `com.zcode.app`。
- 发布后同步仓库门面：About 描述里的"当前版本"（`gh repo edit --description`）、README/README.en 的版本与测试数。

## CI 结果记录

不要手工填写测试数量。把 CI 的 `flutter analyze` 和 `flutter test` 原始结果作为发布证据；若本地没有 Flutter SDK，应明确标记为“未在本地执行”。
