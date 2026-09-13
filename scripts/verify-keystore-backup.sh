#!/usr/bin/env bash
# 签名灾备演练（离线，v1.1.0 / PR18*）：
#   从环境变量恢复 keystore 备份，验证可读且证书指纹与生产一致。
#
# 用法（口令只从环境变量读取，不要放进命令行参数或历史记录）：
#   KEYSTORE_BASE64=... KEYSTORE_PASSWORD=... scripts/verify-keystore-backup.sh
#
# 可选：
#   KEY_ALIAS=zcode-app                      # keystore alias
#   EXPECTED_FINGERPRINT=<64 位小写 hex>     # 默认 = 已发布 APK 的证书 SHA-256
#
# 退出码：0 = 备份可用；1 = 备份不可用或指纹不符；2 = 用法/环境错误。
set -euo pipefail

KEYSTORE_B64="${KEYSTORE_BASE64:-}"
KEYSTORE_PW="${KEYSTORE_PASSWORD:-}"
KEY_ALIAS="${KEY_ALIAS:-zcode-app}"
EXPECTED="${EXPECTED_FINGERPRINT:-07091ffd181696b1b612fa942a048437229c6960de4481fb710983225cf74004}"

if [ -z "${KEYSTORE_B64}" ] || [ -z "${KEYSTORE_PW}" ]; then
  echo "usage: KEYSTORE_BASE64=... KEYSTORE_PASSWORD=... $0" >&2
  echo "（凭据只从环境变量读取；本脚本不打印、不落盘任何口令或私钥）" >&2
  exit 2
fi
if ! command -v keytool >/dev/null 2>&1; then
  echo "keytool not found on PATH (需要 JDK 17 或更新版本)" >&2
  exit 2
fi

WORK="$(mktemp -d)"
cleanup() { rm -rf -- "${WORK:?}"; }
trap cleanup EXIT

# macOS 的 base64 需要 -D；Linux/Git Bash 用 -d。
if ! printf '%s' "${KEYSTORE_B64}" | base64 -d > "${WORK}/restore.jks" 2>/dev/null; then
  printf '%s' "${KEYSTORE_B64}" | base64 -D > "${WORK}/restore.jks"
fi

# 口令优先走环境变量（JDK 9+ 的 -storepass:env），避免出现在进程参数中；
# 若该 JDK 不支持，再退回 -storepass（仅影响口令可见性，不影响校验结果）。
ZCODE_KEYSTORE_PW="${KEYSTORE_PW}"
export ZCODE_KEYSTORE_PW
PROBE="$(keytool -list -keystore "${WORK}/nonexistent-probe.jks" -storepass:env ZCODE_KEYSTORE_PW 2>&1 || true)"
if printf '%s' "${PROBE}" | grep -qiE "does not exist|no such file|not found"; then
  STOREPASS_ARGS=(-storepass:env ZCODE_KEYSTORE_PW)
else
  STOREPASS_ARGS=(-storepass "${KEYSTORE_PW}")
fi

FPR="$(keytool -list -v \
  -keystore "${WORK}/restore.jks" \
  -alias "${KEY_ALIAS}" \
  "${STOREPASS_ARGS[@]}" 2>/dev/null \
  | grep -m1 'SHA256:' \
  | sed -E 's/.*SHA256:[[:space:]]*//' \
  | tr -d ':' \
  | tr 'A-F' 'a-f')"

if [ -z "${FPR}" ]; then
  echo "FAIL: keystore 无法读取（口令/alias 错误，或备份文件损坏）" >&2
  exit 1
fi

if [ "${FPR}" != "${EXPECTED}" ]; then
  echo "FAIL: 证书指纹 ${FPR}" >&2
  echo "      与生产期望 ${EXPECTED} 不一致——用这份备份发布的包无法覆盖存量用户，禁止发布。" >&2
  exit 1
fi

echo "OK: keystore 备份可用，证书指纹与生产一致：${FPR}"
echo "提示：完整演练还应临时用它构建一次 arm64 release 并执行 apksigner verify（不发布）。"
