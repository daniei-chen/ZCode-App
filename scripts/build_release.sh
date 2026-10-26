#!/usr/bin/env bash
# 一键发版（v1.6.1）：把手工五步收敛成一个脚本，消掉流程失误面。
#
# 用法：
#   scripts/build_release.sh <version>    # 例：scripts/build_release.sh 1.6.1
#
# 步骤（任一步失败即停，退出码非 0）：
#   1. 前置检查：版本参数、tag 唯一性、doc-drift、analyze、flutter test
#   2. 构建：flutter build apk --release（注入版本字段）
#      → 修 local.properties 的 flutter.sdk 中文路径
#      → gradlew assembleRelease
#   3. 验签：aapt2 版本元数据 + apksigner 证书指纹 + v2 scheme
#   4. sha256 侧车（与历史格式一致："hash␣␣filename"）
#   5. 发布：git 提交（若有未提交变更）→ push → tag → gh release create
#
# 前提：gh 已登录；release notes 已写好 docs/releases/<version>.md。

set -euo pipefail

SDK_DIR="D:/flutter-sdk"
KEY_SHA256="07091ffd181696b1b612fa942a048437229c6960de4481fb710983225cf74004"
OUT_DIR="D:/ZCode/tmp_manifest/out"
ANDROID_SDK="D:/phone/Android/android-sdk"

if [[ $# -lt 1 ]]; then
  echo "用法: $0 <version>  (例: 1.6.1)"
  exit 1
fi
VERSION="$1"
TAG="v${VERSION}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

step() { echo ""; echo "==== [$1] ===="; }

step "1/5 前置检查"
[[ -f "docs/releases/v${VERSION}.md" ]] || { echo "缺少 docs/releases/${VERSION}.md"; exit 1; }
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "tag ${TAG} 已存在（先 git tag -d 并删远端，或换版本号）"; exit 1
fi
grep -q "^version: ${VERSION}+" pubspec.yaml || {
  echo "pubspec.yaml 版本不是 ${VERSION}（先改 version: ${VERSION}+<code>）"; exit 1
}
python scripts/check-doc-drift.py
FLUTTER="${SDK_DIR}/bin/flutter"
"$FLUTTER" analyze
"$FLUTTER" test

step "2/5 构建"
# 版本注入：flutter build 负责把 pubspec 版本写进 local.properties
# （之后 sed 修 SDK 路径）。flutter build 在本机常因路径乱码失败——
# 属预期，失败后由 gradlew 接管完成构建。
"$FLUTTER" build apk --release >/dev/null 2>&1 || true
sed -i 's|^flutter.sdk=.*|flutter.sdk=D:/flutter-sdk|' android/local.properties
grep -q "flutter.versionName=${VERSION}" android/local.properties || {
  echo "警告：local.properties 版本字段不是 ${VERSION}（flutter build 未写入？）"
}
# 引擎 maven（storage.googleapis.com/download.flutter.io）国内间歇不可达，
# floating version 元数据查询抖动即失败——整轮重试（最多 3 次，间隔 10s）。
BUILD_OK=0
for attempt in 1 2 3; do
  echo "构建尝试 $attempt/3"
  if ( cd android && ./gradlew assembleRelease ); then BUILD_OK=1; break; fi
  [[ $attempt -lt 3 ]] && sleep 10
done
[[ "$BUILD_OK" == "1" ]] || { echo "构建三试均失败（多为网络抖动，稍后重跑脚本即可）"; exit 1; }

APK_SRC="build/app/outputs/apk/release/app-release.apk"
APK="${OUT_DIR}/ZCode-${TAG}.apk"
mkdir -p "$OUT_DIR"
cp "$APK_SRC" "$APK"

step "3/5 验签"
APKSIGNER=$(ls "${ANDROID_SDK}/build-tools/"*/apksigner.bat | sort | tail -1)
AAPT2=$(ls "${ANDROID_SDK}/build-tools/"*/aapt2.exe | sort | tail -1)
"$AAPT2" dump badging "$APK" 2>/dev/null | head -1
ACTUAL_SHA=$("$APKSIGNER" verify --print-certs "$APK" 2>/dev/null | grep "SHA-256" | head -1 | awk '{print $NF}')
if [[ "$ACTUAL_SHA" != "$KEY_SHA256" ]]; then
  echo "签名证书不匹配: $ACTUAL_SHA"; exit 1
fi
"$APKSIGNER" verify -v "$APK" 2>&1 | grep -q "Verified using v2 scheme (APK Signature Scheme v2): true" || {
  echo "v2 签名校验失败"; exit 1
}
echo "签名校验通过（证书 ${ACTUAL_SHA:0:12}…，v2 scheme）"

step "4/5 sha256 侧车"
HASH=$(sha256sum "$APK" | awk '{print $1}')
printf '%s  ZCode-%s.apk\n' "$HASH" "$TAG" > "${APK}.sha256"
( cd "$OUT_DIR" && sha256sum -c "ZCode-${TAG}.apk.sha256" )

# latest.json（v1.8.2）：App 的检查更新主链路读这个文件（走 gh-proxy /
# jsDelivr 镜像 raw），不依赖有匿名限流的 GitHub API。必须在 git commit
# 之前写好，否则这一版发出去后，下一版的检查更新会读到旧版本号。
APK_SIZE=$(stat -c%s "$APK")
NOTES_FIRST_LINE=$(grep -m1 '^# ' "docs/releases/v${VERSION}.md" 2>/dev/null | sed 's/^# //' || echo "")
python3 - "$VERSION" "$TAG" "$HASH" "$APK_SIZE" "$NOTES_FIRST_LINE" <<'PY' > latest.json
import json, sys, datetime
version, tag, sha, size, notes = sys.argv[1:6]
print(json.dumps({
    "version": version,
    "tag": tag,
    "apk": f"ZCode-{tag}.apk",
    "sha256": sha,
    "size": int(size),
    "notes": notes,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
}, ensure_ascii=False, indent=2))
PY
echo "latest.json 已更新："
cat latest.json

step "5/5 发布"
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  git add -A
  git commit -m "release: ${TAG}"
fi
for i in 1 2 3; do git push origin main 2>&1 | tail -1 && break || sleep 5; done
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" \
  --title "${TAG}" \
  --notes-file "docs/releases/v${VERSION}.md" \
  "$APK" "${APK}.sha256"

echo ""
echo "发布完成: https://github.com/daniei-chen/ZCode-App/releases/tag/${TAG}"
echo "本地产物: $APK (sha256 ${HASH:0:12}…)"
